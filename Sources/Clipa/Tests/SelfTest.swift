import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Security
import CSQLCipher
import SwiftUI
import ServiceManagement

enum SelfTest {

    static func makeProbePNG(width: Int, height: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.white.setFill()
        NSRect(
            x: width / 4,
            y: height / 4,
            width: width / 2,
            height: height / 2
        ).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    static func makeProbeImage<V: View>(
        view: V,
        size: NSSize
    ) -> NSBitmapImageRep? {
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(
            in: hosting.bounds
        ) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    static func asyncStoreProbe() -> Int32 {
        var failures = 0
        let finished = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { finished.signal() }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaAsyncStoreProbe-\(UUID().uuidString)",
                    isDirectory: true
                )
            let suite = "ClipaAsyncStoreProbe-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let store = ClipStore(
                baseDirectory: dir,
                settingsStore: SettingsStore(
                    defaults: defaults

                )
            )
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: "async-ui-probe",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "async-ui-probe")
                )
            )
            guard let item = store.items.first else {
                failures += 1
                print("[ASYNC-STORE] fixture missing")
                return
            }

            let privated = await store.togglePrivateAsync(item)
            let privateOK =
                privated && store.items.first?.isPrivate == true
            if !privateOK {
                failures += 1
                print("[ASYNC-STORE] private failed")
            }

            let noted = await store.setNoteAsync("async-note", for: item)
            let noteOK =
                noted && store.items.first?.note == "async-note"
            if !noteOK {
                failures += 1
                print("[ASYNC-STORE] note failed")
            }

            if let existing = store.clip(id: item.id) {
                let deleted = await store.deleteAsync(existing)
                if deleted != .deleted(count: 1) || !store.items.isEmpty {
                    failures += 1
                    print("[ASYNC-STORE] delete failed")
                }
            } else {
                failures += 1
                print("[ASYNC-STORE] delete fixture missing")
            }

            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: "async-clear-target",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "async-clear-target")
                )
            )
            let clearResult = await store.clearAllAsync()
            let clearOK: Bool
            if case .cleared(let deleted) = clearResult {
                clearOK = store.items.isEmpty && deleted == 1
            } else {
                clearOK = false
            }
            if !clearOK {
                failures += 1
                print("[ASYNC-STORE] clear failed")
            }

            let staleEpoch = ClipboardMonitor.shared.currentCaptureEpoch
            ClipboardMonitor.shared.beginClearBarrier()
            let staleAccepted = await store.acceptCaptured(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: Data([7, 8, 9]),
                    imageFormat: "public.png",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(data: Data([7, 8, 9]))
                ),
                captureEpoch: staleEpoch
            )
            let freshAccepted = await store.acceptCaptured(
                NewClip(
                    kind: .text,
                    text: "race-fresh",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "race-fresh")
                ),
                captureEpoch: ClipboardMonitor.shared.currentCaptureEpoch
            )
            let raceOK =
                !staleAccepted
                && freshAccepted
                && store.items.map(\.text).contains("race-fresh")
                && !store.items.contains { $0.kind == .image }
            if !raceOK {
                failures += 1
                print("[ASYNC-STORE] capture race barrier failed")
            }

            let imageDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaAsyncImageCopyProbe-\(UUID().uuidString)",
                    isDirectory: true
                )
            let imageProbeStore = ClipStore(baseDirectory: imageDir)
            let png = Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            )!
            _ = await imageProbeStore.insertCaptureAsync(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: png,
                    imageFormat: "public.png",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(data: png)
                ),
                allowAutoPause: false
            )
            let imageClip = imageProbeStore.items.first { $0.kind == .image }
            let asyncPasteboard = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaAsyncImageCopyProbe-\(UUID().uuidString)"
                )
            )
            var copied = false
            if let imageClip {
                copied = await ClipboardWriter.shared.copyAsync(
                    imageClip,
                    store: imageProbeStore,
                    to: asyncPasteboard
                )
            }
            let copyOK =
                copied
                && asyncPasteboard.data(forType: .png) == png
            if !copyOK {
                failures += 1
                print("[ASYNC-STORE] async image copy failed")
            }
            try? FileManager.default.removeItem(at: imageDir)

            let trimDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaAsyncTrimProbe-\(UUID().uuidString)",
                    isDirectory: true
                )
            let trimSuite = "ClipaAsyncTrimProbe-\(UUID().uuidString)"
            let trimDefaults = UserDefaults(suiteName: trimSuite)!
            let trimStore = ClipStore(
                baseDirectory: trimDir,
                settingsStore: SettingsStore(
                    defaults: trimDefaults

                )
            )
            trimStore.settings.historyLimit = 1
            _ = await trimStore.insertCaptureAsync(
                NewClip(
                    kind: .text,
                    text: "async-trim-old",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "async-trim-old")
                )
            )
            _ = await trimStore.insertCaptureAsync(
                NewClip(
                    kind: .text,
                    text: "async-trim-new",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "async-trim-new")
                ),
                allowAutoPause: false
            )
            let trimOK =
                trimStore.items.count == 1
                && trimStore.items.first?.text == "async-trim-new"
            if !trimOK {
                failures += 1
                print("[ASYNC-STORE] async trim failed")
            }
            trimDefaults.removePersistentDomain(forName: trimSuite)
            try? FileManager.default.removeItem(at: trimDir)

            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        while finished.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if failures == 0 {
            print("[ASYNC-STORE] all checks passed")
        } else {
            print("[ASYNC-STORE] \(failures) checks failed")
        }
        return failures == 0 ? 0 : 1
    }

    static func run() -> Int32 {
        print("========== Clipa Self-Test ==========")
        var failures = 0
        var passed = 0

        func check(_ name: String, _ condition: Bool, detail: String = "") {
            if condition {
                passed += 1
                print("  [PASS] \(name)")
            } else {
                failures += 1
                print("  [FAIL] \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
            }
        }

        func awaitAsync<T>(_ operation: @escaping () async throws -> T) -> T? {
            var result: T?
            var failure: Error?
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    result = try await operation()
                } catch {
                    failure = error
                }
                semaphore.signal()
            }
            semaphore.wait()
            if failure != nil { return nil }
            return result
        }

        func makeStore(_ dir: URL) -> ClipStore {
            let suite = "ClipaStoreTest-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            return ClipStore(
                baseDirectory: dir,
                settingsStore: SettingsStore(
                    defaults: defaults

                )
            )
        }

        do {
            let suite = "ClipaAutoResumeTest-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "autoPauseAtLimit")
            defaults.set(true, forKey: "pauseRecording")
            defaults.set(300, forKey: "historyLimit")
            let settings = SettingsStore(
                defaults: defaults

            )
            settings.autoPausedByLimit = true
            settings.historyLimit = 500
            check(
                "Raising history limit resumes auto-paused recording",
                settings.pauseRecording == false
                    && settings.autoPausedByLimit == false
            )

            let manualSuite = "ClipaManualPauseTest-\(UUID().uuidString)"
            let manualDefaults = UserDefaults(suiteName: manualSuite)!
            manualDefaults.set(true, forKey: "autoPauseAtLimit")
            manualDefaults.set(true, forKey: "pauseRecording")
            manualDefaults.set(300, forKey: "historyLimit")
            let manual = SettingsStore(
                defaults: manualDefaults

            )
            check(
                "A manual pause is not mistaken for an auto pause",
                manual.pauseRecording && manual.autoPausedByLimit == false
            )

            let autoSuite = "ClipaAutoPausePersistTest-\(UUID().uuidString)"
            let autoDefaults = UserDefaults(suiteName: autoSuite)!
            autoDefaults.set(true, forKey: "autoPauseAtLimit")
            autoDefaults.set(true, forKey: "pauseRecording")
            autoDefaults.set(true, forKey: "autoPausedByLimit")
            let reloadedAuto = SettingsStore(
                defaults: autoDefaults

            )
            check(
                "An auto pause survives a relaunch",
                reloadedAuto.pauseRecording
                    && reloadedAuto.autoPausedByLimit
            )
            manualDefaults.removePersistentDomain(forName: manualSuite)
            autoDefaults.removePersistentDomain(forName: autoSuite)
            defaults.removePersistentDomain(forName: suite)
        }

        func tag(_ text: String) -> SmartTag {
            SmartClassifier.inferredTag(text: text, kind: .text)
        }
        check(
            "URL stays plain text",
            tag("https://example.com/a?b=1") == .text
                && ClipboardMonitor.classify("https://example.com/a?b=1") == .text
        )
        check(
            "Source code stays plain text",
            tag("func add() {\n  return 1\n}") == .text
                && ClipboardMonitor.classify("func add() {\n  return 1\n}") == .text
        )
        check("Prose stays plain text", tag("普通的句子") == .text)
        check("YAML classification", tag("name: Tom\nage: 18") == .yaml)
        check(
            "Short JSON classification",
            tag(#"{"name":"tom"}"#) == .json
        )
        check("Shell command stays plain text", tag("git status") == .text)
        check(
            "Bare-domain URL stays plain text",
            tag("github.com/openai/openai-python") == .text
        )

        do {
            let suite = "ClipaBackgroundClassificationTest-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = SettingsStore(
                defaults: defaults

            )
            settings.skipSensitive = false
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaBackgroundClassificationTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let processor = ClipboardProcessor()

            func backgroundClassification(
                _ text: String
            ) -> (kind: ClipKind, smartTag: SmartTag)? {
                let pb = NSPasteboard(
                    name: NSPasteboard.Name(
                        "ClipaBackgroundClassification-\(UUID().uuidString)"
                    )
                )
                pb.clearContents()
                pb.setString(text, forType: .string)
                guard let capture = ClipboardMonitor.inspect(pb) else {
                    return nil
                }
                let policy = CapturePolicySnapshot(settings: settings)
                let decision = processor.process(
                    capture: capture,
                    sourceName: "Test",
                    policy: policy
                )
                guard case .captured(let draft) = decision else {
                    return nil
                }
                return (draft.kind, draft.smartTag ?? .text)
            }

            if let json = backgroundClassification(#"{"name":"tom"}"#) {
                check(
                    "Background capture refines short JSON",
                    json.kind == .text && json.smartTag == .json,
                    detail: "kind=\(json.kind.rawValue) tag=\(json.smartTag.rawValue)"
                )
            } else {
                check(
                    "Background capture refines short JSON",
                    false
                )
            }
            if let command = backgroundClassification("git status") {
                check(
                    "Background capture keeps a shell command as text",
                    command.kind == .text && command.smartTag == .text,
                    detail: "kind=\(command.kind.rawValue) tag=\(command.smartTag.rawValue)"
                )
            } else {
                check(
                    "Background capture keeps a shell command as text",
                    false
                )
            }
            if let url = backgroundClassification(
                "github.com/openai/openai-python"
            ) {
                check(
                    "Background capture keeps a bare URL as text",
                    url.kind == .text && url.smartTag == .text,
                    detail: "kind=\(url.kind.rawValue) tag=\(url.smartTag.rawValue)"
                )
            } else {
                check(
                    "Background capture keeps a bare URL as text",
                    false
                )
            }
            if let yaml = backgroundClassification(
                "name: Tom\nage: 18\ncity: Tokyo"
            ) {
                check(
                    "Background capture refines YAML",
                    yaml.kind == .text && yaml.smartTag == .yaml,
                    detail: "kind=\(yaml.kind.rawValue) tag=\(yaml.smartTag.rawValue)"
                )
            } else {
                check(
                    "Background capture refines YAML",
                    false
                )
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaHistoryCountTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            for index in 0..<3 {
                let text = "needle-\(index)"
                store.insert(
                    NewClip(
                        kind: .text,
                        text: text,
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: text)
                    )
                )
            }
            let yamlText = "name: nginx\nreplicas: 3"
            store.insert(
                NewClip(
                    kind: .text,
                    text: yamlText,
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: yamlText)
                )
            )
            MainActor.assumeIsolated {
                let vm = PanelViewModel(
                    store: store,
                    settings: store.settings
                )
                check(
                    "History count: plain total when nothing is filtered",
                    vm.historyCountText == "共 4 条",
                    detail: vm.historyCountText
                )
                vm.query = "needle"
                vm.refreshSearch()
                check(
                    "History count: reports the filtered rows",
                    vm.historyCountText == "结果 3 条 · 共 4 条",
                    detail: vm.historyCountText
                )
                vm.query = ""
                vm.selectSmartTagFilter(.yaml)
                vm.refreshSearch()
                check(
                    "History count: follows a type filter",
                    vm.historyCountText == "结果 1 条 · 共 4 条",
                    detail: vm.historyCountText
                )
                vm.selectSmartTagFilter(nil)
                vm.refreshSearch()
                check(
                    "History count: returns to the plain total",
                    vm.historyCountText == "共 4 条",
                    detail: vm.historyCountText
                )
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaCopyPayloadTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let store = makeStore(dir)
            let text = "copy-payload-text"
            store.insert(
                NewClip(
                    kind: .text,
                    text: text,
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: text)
                )
            )
            let fileURL = dir.appendingPathComponent("payload.txt")
            try? "payload".write(
                to: fileURL,
                atomically: true,
                encoding: .utf8
            )
            store.insert(
                NewClip(
                    kind: .file,
                    text: "",
                    fileURLs: [fileURL],
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(
                        fileURLs: [fileURL]
                    )
                )
            )
            let png = Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            )!
            store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: png,
                    imageFormat: "public.png",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(data: png)
                )
            )

            for clip in store.items {
                let pb = NSPasteboard(
                    name: NSPasteboard.Name(
                        "ClipaCopyPayload-\(UUID().uuidString)"
                    )
                )
                let copied = ClipboardWriter.shared.copy(
                    clip,
                    store: store,
                    to: pb
                )
                switch clip.kind {
                case .text:
                    check(
                        "Copying text publishes the string",
                        copied && pb.string(forType: .string) == clip.text
                    )
                case .file:
                    check(
                        "Copying a file publishes the URL and the path text",
                        copied
                            && pb.string(forType: .string) == fileURL.path
                            && (pb.types ?? []).contains(.fileURL),
                        detail: "types=\((pb.types ?? []).map(\.rawValue))"
                    )
                case .image:
                    check(
                        "Copying an image publishes image data",
                        copied
                            && (pb.data(forType: .png) != nil
                                || pb.data(forType: .tiff) != nil),
                        detail: "types=\((pb.types ?? []).map(\.rawValue))"
                    )
                }
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let pb = NSPasteboard(name: NSPasteboard.Name("ClipaTest-\(UUID().uuidString)"))
            pb.clearContents()
            pb.setString("Clipa 自检内容-\(UUID().uuidString)", forType: .string)
            let capture = ClipboardMonitor.inspect(pb)
            check(
                "Text pasteboard capture",
                capture?.kind == .text && capture?.text.hasPrefix("Clipa 自检内容") == true,
                detail: capture?.text ?? "nil"
            )
        }

        do {
            let suite = "ClipaConfidentialMarkerTest-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = SettingsStore(
                defaults: defaults

            )
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaConfidentialMarkerTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = ClipStore(baseDirectory: dir)
            let monitor = ClipboardMonitor.shared

            func markedPasteboard(
                _ text: String,
                marker: String?
            ) -> NSPasteboard {
                let pb = NSPasteboard(
                    name: NSPasteboard.Name(
                        "ClipaConfidentialMarker-\(UUID().uuidString)"
                    )
                )
                pb.clearContents()
                pb.setString(text, forType: .string)
                if let marker {

                    pb.setData(
                        Data(marker.utf8),
                        forType: NSPasteboard.PasteboardType(marker)
                    )
                }
                return pb
            }

            func decide(
                _ pb: NSPasteboard,
                from bundleID: String = "com.example.never-heard-of-it"
            ) -> ClipboardMonitor.CaptureDecision {
                monitor.evaluate(
                    pasteboard: pb,
                    frontBundleID: bundleID,
                    sourceName: "UnknownTool",
                    settings: settings,
                    store: store
                )
            }

            check(
                "Confidential marker setting defaults on",
                settings.skipConfidentialPasteboard
            )

            let concealed = decide(
                markedPasteboard(
                    "Xk7m2Qp9vT4w",
                    marker: "org.nspasteboard.ConcealedType"
                )
            )
            check(
                "Concealed pasteboard from an unknown app is not captured",
                concealed == .confidentialSkipped,
                detail: String(describing: concealed)
            )

            let transient = decide(
                markedPasteboard(
                    "程序自己放上去的临时内容",
                    marker: "org.nspasteboard.TransientType"
                )
            )
            check(
                "Transient pasteboard is not captured",
                transient == .confidentialSkipped,
                detail: String(describing: transient)
            )

            let sealedImage = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaConfidentialImage-\(UUID().uuidString)"
                )
            )
            sealedImage.clearContents()
            sealedImage.setData(
                Data(
                    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
                )!,
                forType: .png
            )
            sealedImage.setData(
                Data("1".utf8),
                forType: NSPasteboard.PasteboardType(
                    "org.nspasteboard.ConcealedType"
                )
            )
            let imageDecision = decide(sealedImage)
            check(
                "Concealed image pasteboard is not captured",
                imageDecision == .confidentialSkipped,
                detail: String(describing: imageDecision)
            )

            let markerOnly = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaConfidentialEmpty-\(UUID().uuidString)"
                )
            )
            markerOnly.clearContents()
            markerOnly.setData(
                Data("1".utf8),
                forType: NSPasteboard.PasteboardType(
                    "org.nspasteboard.ConcealedType"
                )
            )
            let emptyDecision = decide(markerOnly)
            check(
                "Marker-only pasteboard is skipped, never an empty clip",
                emptyDecision == .confidentialSkipped,
                detail: String(describing: emptyDecision)
            )

            let plain = decide(markedPasteboard("普通的一段文本", marker: nil))
            if case .captured(let item) = plain {
                check(
                    "Unmarked pasteboard from the same unknown app is captured",
                    item.text == "普通的一段文本"
                )
            } else {
                check(
                    "Unmarked pasteboard from the same unknown app is captured",
                    false,
                    detail: String(describing: plain)
                )
            }

            settings.skipConfidentialPasteboard = false
            let optedOut = decide(
                markedPasteboard(
                    "Xk7m2Qp9vT4w",
                    marker: "org.nspasteboard.ConcealedType"
                )
            )
            if case .captured(let item) = optedOut {
                check(
                    "Turning the setting off records marked content again",
                    item.text == "Xk7m2Qp9vT4w"
                )
            } else {
                check(
                    "Turning the setting off records marked content again",
                    false,
                    detail: String(describing: optedOut)
                )
            }

            settings.skipConfidentialPasteboard = true
            check(
                "Confidential marker setting persists when on",
                SettingsStore(
                    defaults: defaults

                ).skipConfidentialPasteboard
            )
            settings.skipConfidentialPasteboard = false
            check(
                "Confidential marker setting persists when off",
                !SettingsStore(
                    defaults: defaults

                ).skipConfidentialPasteboard
            )

            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let pb = NSPasteboard(
                name: NSPasteboard.Name("ClipaRTFTest-\(UUID().uuidString)")
            )
            pb.clearContents()
            let rich = NSAttributedString(
                string: "Clipa 复杂 RTF 内容"
            )
            if let data = try? rich.data(
                from: NSRange(location: 0, length: rich.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.rtf
                ]
            ) {
                pb.setData(data, forType: .rtf)
                let capture = ClipboardMonitor.inspect(pb)
                check(
                    "Rich RTF pasteboard captures the copied text",
                    capture.map(ClipboardProcessor.resolvedText(from:))
                        == "Clipa 复杂 RTF 内容"
                )

                check(
                    "Rich RTF pasteboard never queues an HTML import",
                    capture?.htmlData == nil,
                    detail: String(describing: capture?.htmlData?.count)
                )
            } else {
                check(
                    "Rich RTF pasteboard captures the copied text",
                    false
                )
                check(
                    "Rich RTF pasteboard never queues an HTML import",
                    false
                )
            }
        }

        do {
            let pb = NSPasteboard(
                name: NSPasteboard.Name("ClipaHTMLTest-\(UUID().uuidString)")
            )
            pb.clearContents()
            let html = NSAttributedString(
                string: "Clipa 复杂 HTML 内容"
            )
            if let data = try? html.data(
                from: NSRange(location: 0, length: html.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.html
                ]
            ) {
                pb.setData(data, forType: .html)
                let capture = ClipboardMonitor.inspect(pb)
                check(
                    "Rich HTML pasteboard stays undecoded on the main thread",
                    capture?.text.isEmpty == true && capture?.htmlData != nil,
                    detail: String(describing: capture?.htmlData?.count)
                )
                check(
                    "Rich HTML pasteboard decodes to the copied text",
                    capture.map(ClipboardProcessor.resolvedText(from:))
                        == "Clipa 复杂 HTML 内容"
                )
            } else {
                check(
                    "Rich HTML pasteboard stays undecoded on the main thread",
                    false
                )
                check("Rich HTML pasteboard decodes to the copied text", false)
            }
        }

        do {
            if let probe = LoopbackConnectionProbe() {
                probe.start()
                defer { probe.stop() }

                let html = """
                    <html><head>
                    <link rel="stylesheet" href="http://127.0.0.1:\(probe.port)/a.css">
                    <style>body{background:url(http://127.0.0.1:\(probe.port)/b.png)}</style>
                    <meta http-equiv="refresh" content="0;url=http://127.0.0.1:\(probe.port)/c">
                    </head><body>
                    <p>正文 你好</p>
                    <img src="http://127.0.0.1:\(probe.port)/pixel.png" alt="图">
                    <a href="http://127.0.0.1:\(probe.port)/d">链接</a>
                    </body></html>
                    """

                let sanitized = RichTextDecoder.sanitizedHTML(html)
                check(
                    "HTML sanitizer removes every remote reference",
                    !sanitized.contains("127.0.0.1")
                        && !sanitized.lowercased().contains("http")
                        && !sanitized.lowercased().contains("url("),
                    detail: sanitized
                )
                check(
                    "HTML sanitizer keeps the readable text",
                    sanitized.contains("正文 你好")
                        && sanitized.contains("链接")
                )
                var imageOnlyHTML = CaptureResult(
                    kind: .text,
                    text: "",
                    imageData: nil,
                    tiffImageData: nil,
                    imageFileURL: nil,
                    fileURLs: []
                )
                imageOnlyHTML.htmlData = Data(
                    #"<p><img src="http://127.0.0.1:9/a.png"></p>"#.utf8
                )
                check(
                    "Image-only HTML yields no text instead of a placeholder",
                    ClipboardProcessor.resolvedText(from: imageOnlyHTML).isEmpty,
                    detail: ClipboardProcessor.resolvedText(from: imageOnlyHTML)
                )

                let pb = NSPasteboard(
                    name: NSPasteboard.Name(
                        "ClipaHTMLNetwork-\(UUID().uuidString)"
                    )
                )
                pb.clearContents()
                pb.setData(Data(html.utf8), forType: .html)

                let suite = "ClipaHTMLNetworkTest-\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                let settings = SettingsStore(
                    defaults: defaults

                )
                if let capture = ClipboardMonitor.inspect(pb) {
                    let decision = ClipboardProcessor().process(
                        capture: capture,
                        sourceName: "Safari",
                        policy: CapturePolicySnapshot(settings: settings)
                    )

                    Thread.sleep(forTimeInterval: 1.5)
                    check(
                        "Clipboard HTML opens no connection",
                        probe.connectionCount == 0,
                        detail: "connections=\(probe.connectionCount)"
                    )
                    if case .captured(let draft) = decision {
                        check(
                            "Clipboard HTML still yields the visible text",
                            draft.text.contains("正文 你好")
                                && draft.text.contains("链接"),
                            detail: draft.text
                        )
                    } else {
                        check(
                            "Clipboard HTML still yields the visible text",
                            false,
                            detail: String(describing: decision)
                        )
                    }
                } else {
                    check(
                        "Clipboard HTML opens no connection",
                        false,
                        detail: "no capture"
                    )
                }

                let control = URL(
                    string: "http://127.0.0.1:\(probe.port)/control"
                )!
                let semaphore = DispatchSemaphore(value: 0)
                URLSession.shared.dataTask(with: control) { _, _, _ in
                    semaphore.signal()
                }.resume()
                _ = semaphore.wait(timeout: .now() + 5)
                check(
                    "Loopback probe observes a real connection",
                    probe.connectionCount > 0,
                    detail: "connections=\(probe.connectionCount)"
                )
                defaults.removePersistentDomain(forName: suite)
            } else {
                check(
                    "Clipboard HTML opens no connection",
                    false,
                    detail: "loopback probe unavailable"
                )
            }
        }

        do {
            let pb = NSPasteboard(name: NSPasteboard.Name("ClipaURLTest-\(UUID().uuidString)"))
            pb.clearContents()
            pb.setString("https://www.swift.org", forType: .string)
            let capture = ClipboardMonitor.inspect(pb)
            check("URL pasteboard capture stays text", capture?.kind == .text, detail: capture?.text ?? "nil")
        }

        do {
            let pb = NSPasteboard(name: NSPasteboard.Name("ClipaImageTest-\(UUID().uuidString)"))
            pb.clearContents()
            let png = Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            )!
            pb.setData(png, forType: .png)
            let capture = ClipboardMonitor.inspect(pb)
            check(
                "Image pasteboard capture",
                capture?.kind == .image && capture?.imageData != nil,
                detail: String(describing: capture?.kind)
            )
        }

        do {

            let pb = NSPasteboard(name: NSPasteboard.Name("ClipaTIFFTest-\(UUID().uuidString)"))
            pb.clearContents()
            let png = Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            )!
            guard let tiff = NSImage(data: png)?.tiffRepresentation else {
                check("Background image conversion saves PNG", false, detail: "TIFF fixture unavailable")
                return Int32(failures)
            }
            pb.setData(tiff, forType: .tiff)
            let rawCapture = ClipboardMonitor.inspect(pb)
            check(
                "TIFF pasteboard capture defers PNG conversion",
                rawCapture?.kind == .image
                    && rawCapture?.imageData == nil
                    && rawCapture?.tiffImageData != nil,
                detail: String(describing: rawCapture?.kind)
            )

            let suite = "ClipaCaptureProcessorTest-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = SettingsStore(
                defaults: defaults

            )
            settings.skipSensitive = false
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaCaptureProcessorTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let processor = ClipboardProcessor()
            let decision = processor.process(
                capture: CaptureResult(
                    kind: .image,
                    text: "",
                    imageData: nil,
                    tiffImageData: tiff,
                    imageFileURL: nil,
                    fileURLs: []
                ),
                sourceName: "Test",
                policy: CapturePolicySnapshot(settings: settings)
            )
            if case .captured(let draft) = decision,
               let stored = draft.imageData {
                check(
                    "Background image conversion saves PNG",
                    draft.contentHash != nil
                        && draft.imageFormat == "public.png"
                        && stored.count > 8
                        && stored.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                )
            } else {
                check("Background image conversion saves PNG", false)
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }

        do {

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaImageFileCaptureTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let sourceURL = root.appendingPathComponent("source.png")
            let png = Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            )!
            try? png.write(to: sourceURL)

            let pb = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaImageFileCaptureTest-\(UUID().uuidString)"
                )
            )
            pb.clearContents()
            pb.writeObjects([sourceURL as NSURL])

            let iconRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 16,
                pixelsHigh: 16,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            if let iconTiff = iconRep.representation(
                using: .tiff,
                properties: [:]
            ) {
                pb.setData(iconTiff, forType: .tiff)
            }
            let capture = ClipboardMonitor.inspect(pb)
            check(
                "File-manager image copy is detected as image source",
                capture?.kind == .image
                    && capture?.imageFileURL == sourceURL,
                detail: String(describing: capture?.kind)
            )

            let suite = "ClipaImageFileProcessorTest-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = SettingsStore(
                defaults: defaults

            )
            settings.skipSensitive = false
            let processor = ClipboardProcessor()
            if let capture {
                let decision = processor.process(
                    capture: capture,
                    sourceName: "Finder",
                    policy: CapturePolicySnapshot(settings: settings)
                )
                if case .captured(let draft) = decision,
                   draft.kind == .image,
                   let stored = draft.imageData {
                    check(
                        "Finder icon TIFF never replaces the original file bytes",
                        draft.fileURLs.isEmpty
                            && draft.imageFormat == "public.png"
                            && stored == png
                    )
                } else {
                    check(
                        "Finder icon TIFF never replaces the original file bytes",
                        false
                    )
                }
            }

            let badURL = root.appendingPathComponent("broken.png")
            try? Data("not-an-image".utf8).write(to: badURL)
            let badPB = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaBrokenImageFileTest-\(UUID().uuidString)"
                )
            )
            badPB.clearContents()
            badPB.writeObjects([badURL as NSURL])
            if let badCapture = ClipboardMonitor.inspect(badPB) {
                let decision = processor.process(
                    capture: badCapture,
                    sourceName: "Finder",
                    policy: CapturePolicySnapshot(settings: settings)
                )
                if case .captured(let draft) = decision {
                    check(
                        "Image file with undecodable bytes keeps its bytes",
                        draft.kind == .image
                            && draft.imageData == Data("not-an-image".utf8)
                    )
                } else {
                    check(
                        "Image file with undecodable bytes keeps its bytes",
                        false
                    )
                }
            } else {
                check(
                    "Image file with undecodable bytes keeps its bytes",
                    false
                )
            }

            let swiftURL = root.appendingPathComponent("Package.swift")
            try? Data("// swift-tools-version: 5.9".utf8).write(to: swiftURL)
            let filePB = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaFinderFileCaptureTest-\(UUID().uuidString)"
                )
            )
            filePB.clearContents()
            filePB.writeObjects([swiftURL as NSURL])
            filePB.setData(
                Data("finder-flavor".utf8),
                forType: NSPasteboard.PasteboardType(
                    "com.apple.finder.noderef"
                )
            )
            filePB.setString(
                "Package.swift",
                forType: .string
            )
            if let iconRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1024,
                pixelsHigh: 1024,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let iconTiff = iconRep.representation(
                using: .tiff,
                properties: [:]
            ) {
                filePB.setData(iconTiff, forType: .tiff)
            }
            if let fileCapture = ClipboardMonitor.inspect(filePB) {
                let decision = processor.process(
                    capture: fileCapture,
                    sourceName: "Finder",
                    policy: CapturePolicySnapshot(settings: settings)
                )
                if case .captured(let draft) = decision {
                    check(
                        "Finder file copy stays a file clip, not its icon",
                        draft.kind == .file
                            && draft.fileURLs == [swiftURL]
                            && draft.imageData == nil
                    )
                } else {
                    check(
                        "Finder file copy stays a file clip, not its icon",
                        false
                    )
                }
            } else {
                check(
                    "Finder file copy stays a file clip, not its icon",
                    false
                )
            }

            let goneURL = root.appendingPathComponent("gone.png")
            let gonePB = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaGoneImageCaptureTest-\(UUID().uuidString)"
                )
            )
            gonePB.clearContents()
            gonePB.writeObjects([goneURL as NSURL])
            if let iconRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 64,
                pixelsHigh: 64,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let iconTiff = iconRep.representation(
                using: .tiff,
                properties: [:]
            ) {
                gonePB.setData(iconTiff, forType: .tiff)
            }
            if let goneCapture = ClipboardMonitor.inspect(gonePB) {
                let decision = processor.process(
                    capture: goneCapture,
                    sourceName: "Finder",
                    policy: CapturePolicySnapshot(settings: settings)
                )
                if case .captured(let draft) = decision {
                    check(
                        "Missing image file falls back to a file clip, not its icon",
                        draft.kind == .file
                            && draft.fileURLs == [goneURL]
                            && draft.imageData == nil
                    )
                } else {
                    check(
                        "Missing image file falls back to a file clip, not its icon",
                        false
                    )
                }
            } else {
                check(
                    "Missing image file falls back to a file clip, not its icon",
                    false
                )
            }

            let bigURL = root.appendingPathComponent("big.png")
            FileManager.default.createFile(
                atPath: bigURL.path,
                contents: nil
            )
            if let handle = try? FileHandle(forWritingTo: bigURL) {
                try? handle.truncate(atOffset: 31 * 1_000_000)
                try? handle.close()
            }
            let bigPB = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaOversizeImageCaptureTest-\(UUID().uuidString)"
                )
            )
            bigPB.clearContents()
            bigPB.writeObjects([bigURL as NSURL])
            if let bigCapture = ClipboardMonitor.inspect(bigPB) {
                let decision = processor.process(
                    capture: bigCapture,
                    sourceName: "Finder",
                    policy: CapturePolicySnapshot(settings: settings)
                )
                if case .captured(let draft) = decision {
                    check(
                        "Oversize image file is rejected before reading",
                        draft.kind == .file
                            && draft.fileURLs == [bigURL]
                            && draft.imageData == nil
                    )
                } else {
                    check(
                        "Oversize image file is rejected before reading",
                        false
                    )
                }
            } else {
                check(
                    "Oversize image file is rejected before reading",
                    false
                )
            }

            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        do {
            func newClip(
                _ text: String,
                kind: ClipKind = .text,
                source: String? = nil,
                note: String = "",
                hash: String? = nil
            ) -> NewClip {
                NewClip(
                    kind: kind,
                    text: text,
                    note: note,
                    sourceApp: source,
                    contentHash: hash ?? ContentHasher.hash(text: text)
                )
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaStoreTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            store.insert(newClip("hello world", source: "Test"))
            store.insert(newClip("hello world", source: "Another"))
            check("Dedupe keeps single record", store.items.count == 1, detail: "count=\(store.items.count)")

            guard !store.items.isEmpty else {
                check("Store contains item", false)
                return Int32(failures)
            }
            _ = store.setNote("测试备注", for: store.items.first!)
            check("Note saved", store.items.first?.note == "测试备注")
            if let noted = store.items.first {
                check(
                    "Note search matches",
                    store.memoryIndex.containsAllTerms(
                        dbID: noted.dbID,
                        terms: ["备注"]
                    )
                )
            } else {
                check("Note search matches", false)
            }

            let searchable = Clip(
                dbID: -1,
                id: UUID(),
                kind: .text,
                text: "Hello World",
                note: "Hello World",
                sourceApp: "Xcode",
                createdAt: Date(),
                lastCopiedAt: Date(),
                updatedAt: Date()
            )
            store.memoryIndex.insert(clip: searchable)
            check(
                "Search is case-insensitive",
                store.memoryIndex.containsAllTerms(dbID: searchable.dbID, terms: ["hello"])
                    && store.memoryIndex.containsAllTerms(dbID: searchable.dbID, terms: ["world"])
            )
            check(
                "Search does not match source app",
                !store.memoryIndex.containsAllTerms(dbID: searchable.dbID, terms: ["xcode"])
            )

            let reloaded = makeStore(dir)
            check("Persistence round-trip", reloaded.items.count == 1 && reloaded.items.first?.note == "测试备注")
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaSourceBundleTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            store.insert(
                NewClip(
                    kind: .text,
                    text: "source-bundle-roundtrip",
                    sourceApp: "备忘录",
                    sourceBundle: "com.apple.Notes",
                    contentHash: ContentHasher.hash(
                        text: "source-bundle-roundtrip"
                    )
                )
            )
            let reloaded = makeStore(dir)
            let row = reloaded.items.first {
                $0.text == "source-bundle-roundtrip"
            }
            check(
                "Source bundle id persists and round-trips",
                row?.sourceBundle == "com.apple.Notes"
                    && row?.sourceApp == "备忘录"
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let token = "clipa_test_token_123"
            let helper = "/Applications/Clipa.app/Contents/Helpers/clipa-mcp"
            let cursor = APIMcp.cursorConfig(token: token, helperPath: helper)
            let cursorJSON = try? JSONSerialization.jsonObject(
                with: Data(cursor.utf8)
            ) as? [String: Any]
            let server = (cursorJSON?["mcpServers"] as? [String: Any])?["clipa"]
                as? [String: Any]
            let env = server?["env"] as? [String: String]
            check(
                "Cursor MCP config is valid JSON carrying the token",
                server?["command"] as? String == helper && env?["CLIPA_TOKEN"] == token
            )
            let codex = APIMcp.codexConfig(token: token, helperPath: helper)
            check(
                "Codex MCP config carries command and token env",
                codex.contains("[mcp_servers.clipa]")
                    && codex.contains("command = \"\(helper)\"")
                    && codex.contains("CLIPA_TOKEN = \"\(token)\"")
            )
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaCipherHeaderTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            store.insert(
                NewClip(
                    kind: .text,
                    text: "cipher-header-fixture",
                    contentHash: ContentHasher.hash(
                        text: "cipher-header-fixture"
                    )
                )
            )
            let dbPath = dir.appendingPathComponent("clips.sqlite").path
            var header = Data()
            if let handle = FileHandle(forReadingAtPath: dbPath) {
                header = handle.readData(ofLength: 16)
                try? handle.close()
            }
            let plainMagic = Data("SQLite format 3\0".utf8)
            check(
                "DB file at rest is not plaintext SQLite",
                header != plainMagic && !header.isEmpty
            )
            check(
                "SQLCipher codec compiled in",
                sqlite3_compileoption_used("SQLITE_HAS_CODEC") == 1
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaCipherMigrationTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            let dbPath = dir.appendingPathComponent("clips.sqlite").path

            var raw: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
                | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(dbPath, &raw, flags, nil) == SQLITE_OK,
                  let raw else {
                sqlite3_close(raw)
                check("Legacy plaintext db opens for fixture", false)
                return Int32(failures)
            }

            sqlite3_exec(raw, DatabaseSchema.clipsTable, nil, nil, nil)
            sqlite3_exec(
                raw,
                "INSERT INTO clips(id, kind, text, created_at, updated_at) "
                    + "VALUES('AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0000', 0, "
                    + "'legacy-plaintext-row', 0, 0);",
                nil, nil, nil
            )
            sqlite3_close(raw)
            var probe: OpaquePointer?
            sqlite3_open_v2(dbPath, &probe, flags, nil)
            var preCount: Int = -1
            if let probe {
                sqlite3_exec(
                    probe,
                    "SELECT count(*) FROM clips", nil, nil, nil
                )

                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(
                    probe, "SELECT count(*) FROM clips", -1, &stmt, nil
                ) == SQLITE_OK {
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        preCount = Int(sqlite3_column_int(stmt, 0))
                    }
                    sqlite3_finalize(stmt)
                }
                sqlite3_close(probe)
            }
            NSLog("Clipa DBG 夹具迁移前行数=\(preCount)")

            let store = makeStore(dir)
            let migratedHeader = (try? Data(
                contentsOf: dir.appendingPathComponent("clips.sqlite")
            ))?.prefix(16) ?? Data()
            let rowReadable = store.items.contains {
                $0.text == "legacy-plaintext-row"
            }
            NSLog("Clipa DBG items=\(store.items.map(\.text))")
            NSLog("Clipa DBG 可用性=\(String(describing: store.availability.reason)) database=\(store.database != nil)")
            let store2 = makeStore(dir)
            NSLog("Clipa DBG items2=\(store2.items.map(\.text))")
            let headerEncrypted =
                migratedHeader != Data("SQLite format 3\0".utf8)
            let backupPresent = FileManager.default.fileExists(
                atPath: dbPath + ".plain-backup"
            )
            check(
                "Legacy plaintext db migrates to encrypted at open",
                rowReadable && headerEncrypted && backupPresent,
                detail: "row=\(rowReadable) header=\(headerEncrypted)"
                    + " backup=\(backupPresent)"
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaSQLiteTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            func draft(
                _ text: String,
                kind: ClipKind = .text,
                source: String? = nil,
                note: String? = nil
            ) -> NewClip {
                NewClip(
                    kind: kind,
                    text: text,
                    note: note ?? text,
                    sourceApp: source,
                    contentHash: ContentHasher.hash(text: text)
                )
            }
            store.insert(draft("kubernetes deployment rollback", source: "Chrome"))
            store.insert(draft("今天部署上线新的版本", source: "Slack"))
            store.insert(draft("temporary row", source: "Test"))
            guard let removable = store.items.first(where: { $0.text == "temporary row" }) else {
                check("Store contains removable row", false)
                return Int32(failures)
            }
            store.delete(removable)
            check(
                "Store delete removes row",
                !store.items.contains { $0.id == removable.id }
            )

            let png = Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            )!
            let imageDraft = NewClip(
                kind: .image,
                text: "",
                imageData: png,
                imageFormat: "public.png",
                contentHash: ContentHasher.hash(data: png)
            )
            store.insert(imageDraft)
            guard let imageItem = store.items.first(where: {
                $0.kind == .image
            }) else {
                check("Image clip inserted", false)
                return Int32(failures)
            }
            check("Image clip inserted", true)
            check(
                "Image bytes stored",
                store.imageData(for: imageItem) == png
            )
            store.delete(imageItem)
            check(
                "Image bytes removed on delete",
                store.imageData(for: imageItem) == nil
            )

            guard let database = store.database else {
                check("DatabaseManager available", false)
                return Int32(failures)
            }
            func candidateCount(for term: String) -> Int {
                guard let ftsQuery = FTSQueryBuilder.buildANDQuery(terms: [term]) else {
                    return -1
                }
                do {
                    let recall = try DatabaseSync.run(database) { db in
                        try await db.ftsCandidateIDs(query: ftsQuery)
                    }
                    return recall.ids.count
                } catch {
                    return -1
                }
            }
            check("FTS5 matches ASCII", candidateCount(for: "kubernetes") == 1)
            check("FTS5 trigram matches CJK", candidateCount(for: "部署上线") == 1)
            check(
                "FTS5 falls back for short query",
                candidateCount(for: "ab") == -1
            )

            let engine = LocalSearchEngine(database: database)
            let asciiResult = engine.search(
                query: "kubernetes",
                filter: SearchFilter(),
                store: store
            )
            check(
                "FTS5 recall + memory validation",
                asciiResult.clips.count == 1
                    && asciiResult.clips.first?.text == "kubernetes deployment rollback"
            )
            let shortResult = engine.search(
                query: "ab",
                filter: SearchFilter(),
                store: store
            )
            check(
                "Short query falls back to memory",
                shortResult.clips.isEmpty
            )
            let chineseResult = engine.search(
                query: "部署",
                filter: SearchFilter(),
                store: store
            )
            if let item = chineseResult.clips.first {
                store.delete(item)
            }
            check("FTS5 syncs on delete", candidateCount(for: "部署上线") == 0)

            store.insert(draft("clear me", source: "Test"))
            store.clearAll()
            check("Clear empties the history", store.items.isEmpty)

            check(
                "Time bucket: today",
                ClipGrouper.bucket(for: Date(), calendar: .current) == .today
            )
            check(
                "Time bucket: yesterday",
                ClipGrouper.bucket(
                    for: Date().addingTimeInterval(-86400),
                    calendar: .current
                ) == .yesterday
            )
            check(
                "Time bucket: older",
                ClipGrouper.bucket(
                    for: Date().addingTimeInterval(-3 * 86400),
                    calendar: .current
                ) == .earlier
            )

            let migrationDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaMigrationTest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: migrationDir, withIntermediateDirectories: true)
            let legacyObject: [String: Any] = [
                "id": UUID().uuidString,
                "kind": "text",
                "text": "legacy item",
                "fileURLs": [] as [String],
                "sourceApp": "Test",
                "createdAt": Date().timeIntervalSince1970,
                "updatedAt": Date().timeIntervalSince1970,
                "isPinned": false,
                "isHidden": false,
                "isPrivate": false
            ]
            let jsonData = try? JSONSerialization.data(
                withJSONObject: [legacyObject],
                options: []
            )
            try? jsonData?.write(to: migrationDir.appendingPathComponent("clips.json"))
            let migrated = makeStore(migrationDir)
            check("SQLite migrates legacy JSON",
                  migrated.items.count == 1 && migrated.items.first?.text == "legacy item")
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: migrationDir)

            let v1Dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaV1MigrationTest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: v1Dir,
                withIntermediateDirectories: true
            )
            let v1Path = v1Dir.appendingPathComponent("clips.sqlite").path
            do {
                let conn = try DatabaseConnection(path: v1Path)
                try conn.configure()
                try conn.exec("""
                    CREATE TABLE clips (
                        position INTEGER NOT NULL,
                        id TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        text TEXT NOT NULL DEFAULT '',
                        image_file TEXT,
                        file_urls TEXT NOT NULL DEFAULT '[]',
                        source_app TEXT,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        is_pinned INTEGER NOT NULL DEFAULT 0,
                        is_private INTEGER NOT NULL DEFAULT 0,
                        note TEXT,
                        is_hidden INTEGER NOT NULL DEFAULT 0
                    );
                    """)
                try conn.exec("""
                    CREATE VIRTUAL TABLE clips_fts USING fts5(
                        text, note, source_app, id UNINDEXED,
                        tokenize='trigram'
                    );
                    """)
                let legacyID = UUID().uuidString
                try conn.exec("""
                    INSERT INTO clips (
                        position, id, kind, text, file_urls, source_app,
                        created_at, updated_at, is_pinned, note
                    )
                    VALUES (
                        0, '\(legacyID)', 'text', 'v1 row body',
                        '[]', 'Safari', 1700000000, 1700000000, 1, 'v1 note'
                    )
                    """)
                try conn.exec("""
                    INSERT INTO clips_fts (text, note, source_app, id)
                    VALUES ('v1 row body', 'v1 note', 'Safari', '\(legacyID)')
                    """)
            } catch {
                check("v1 schema created", false, detail: error.localizedDescription)
            }
            let v2Store = makeStore(v1Dir)
            check(
                "v1 table migrates without data loss",
                v2Store.items.count == 1
                    && v2Store.items.first?.text == "v1 row body"
                    && v2Store.items.first?.note == "v1 note"
            )
            if let manager = v2Store.database,
               let ftsCount = try? DatabaseSync.run(
                   manager,
                   { db in try await db.ftsCount() }
               ) {
                check(
                    "v2 clips / clips_fts counts aligned",
                    ftsCount == v2Store.items.count
                )
            } else {
                check("v2 clips / clips_fts counts aligned", false)
            }
            check(
                "v2 schema has db_id and drops source_app FTS",
                {
                    guard let conn = try? DatabaseConnection(path: v1Path),
                          let sql = conn.ftsColumnList(for: "clips_fts") else {
                        return false
                    }
                    return conn.hasColumn(table: "clips", column: "db_id")
                        && !sql.contains("source_app")
                }()
            )
            try? FileManager.default.removeItem(at: v1Dir)

            let v2Dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaV2toV3Test-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: v2Dir,
                withIntermediateDirectories: true
            )
            let v2Path = v2Dir.appendingPathComponent("clips.sqlite").path
            do {
                let conn = try DatabaseConnection(path: v2Path)
                try conn.configure()
                try conn.exec("""
                    CREATE TABLE clips (
                        db_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        id TEXT NOT NULL UNIQUE,
                        kind TEXT NOT NULL,
                        text TEXT NOT NULL DEFAULT '',
                        note TEXT NOT NULL DEFAULT '',
                        image_file TEXT,
                        file_urls TEXT NOT NULL DEFAULT '[]',
                        source_app TEXT,
                        created_at INTEGER NOT NULL,
                        last_copied_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        is_pinned INTEGER NOT NULL DEFAULT 0,
                        is_private INTEGER NOT NULL DEFAULT 0,
                        is_hidden INTEGER NOT NULL DEFAULT 0,
                        content_hash TEXT
                    );
                    """)
                try conn.exec("""
                    CREATE VIRTUAL TABLE clips_fts USING fts5(
                        text, note, tokenize='trigram'
                    );
                    """)
                try conn.exec("PRAGMA user_version = 2")
                let v2ID = UUID().uuidString
                let stamp = Int64(Date().timeIntervalSince1970)
                try conn.exec("""
                    INSERT INTO clips (
                        db_id, id, kind, text, note, file_urls,
                        created_at, last_copied_at, updated_at
                    )
                    VALUES (1, '\(v2ID)', 'text', 'v2 row', '', '[]',
                            \(stamp), \(stamp), \(stamp))
                    """)
                try FTSRepository.insert(
                    rowid: 1,
                    text: "v2 row",
                    note: "",
                    indexed: true,
                    connection: conn
                )
            } catch {
                check("v2 schema created", false, detail: error.localizedDescription)
            }
            let v3Store = makeStore(v2Dir)
            check(
                "v2→v3 migration keeps the row readable",
                v3Store.items.count == 1
                    && v3Store.items.first?.text == "v2 row"
            )
            try? FileManager.default.removeItem(at: v2Dir)
        }

        do {
            let v3Dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaV3toV4Test-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: v3Dir,
                withIntermediateDirectories: true
            )
            let v3Path = v3Dir.appendingPathComponent("clips.sqlite").path
            do {
                let conn = try DatabaseConnection(path: v3Path)
                try conn.configure()
                try conn.exec("""
                    CREATE TABLE clips (
                        db_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        id TEXT NOT NULL UNIQUE,
                        kind TEXT NOT NULL,
                        text TEXT NOT NULL DEFAULT '',
                        note TEXT NOT NULL DEFAULT '',
                        image_file TEXT,
                        file_urls TEXT NOT NULL DEFAULT '[]',
                        source_app TEXT,
                        created_at INTEGER NOT NULL,
                        last_copied_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        is_pinned INTEGER NOT NULL DEFAULT 0,
                        is_private INTEGER NOT NULL DEFAULT 0,
                        is_hidden INTEGER NOT NULL DEFAULT 0,
                        ai_visibility INTEGER NOT NULL DEFAULT 0,
                        content_hash TEXT
                    );
                    """)
                try conn.exec("PRAGMA user_version = 3")
                let rowID = UUID().uuidString
                let stamp = Int64(Date().timeIntervalSince1970)
                try conn.exec("""
                    INSERT INTO clips (
                        db_id, id, kind, text, note, file_urls,
                        created_at, last_copied_at, updated_at
                    )
                    VALUES (1, '\(rowID)', 'code', 'v3 row', '', '[]',
                            \(stamp), \(stamp), \(stamp))
                    """)
            } catch {
                check("v3 schema created", false, detail: error.localizedDescription)
            }
            let v4Store = makeStore(v3Dir)
            let layoutOK: Bool = {
                guard let conn = try? DatabaseConnection(path: v3Path) else {
                    return false
                }
                let kind = conn.columnType(table: "clips", column: "kind")
                    .map { $0.uppercased() }
                let created = conn.columnType(table: "clips", column: "created_at")
                    .map { $0.uppercased() }
                let last = conn.columnType(table: "clips", column: "last_copied_at")
                    .map { $0.uppercased() }
                return kind == "INTEGER"
                    && created == "REAL"
                    && last == "REAL"
                    && conn.userVersion() == DatabaseSchema.currentUserVersion
                    && conn.hasColumn(
                        table: "clips",
                        column: "smart_tag"
                    )
            }()
            check(
                "v3→v4 migration converts kind/timestamps and bumps version",
                v4Store.items.count == 1
                    && v4Store.items.first?.text == "v3 row"
                    && v4Store.items.first?.kind == .text
                    && layoutOK
            )
            try? FileManager.default.removeItem(at: v3Dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaShortCaptureTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            let suite = "ClipaShortCaptureTest-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = SettingsStore(
                defaults: defaults

            )
            let processor = ClipboardProcessor()
            let decision = processor.process(
                capture: CaptureResult(
                    kind: .text,
                    text: "嗯",
                    imageData: nil,
                    tiffImageData: nil,
                    imageFileURL: nil,
                    fileURLs: []
                ),
                sourceName: "Test",
                policy: CapturePolicySnapshot(settings: settings)
            )
            if case .captured(let draft) = decision {
                check(
                    "A one-character copy survives the capture policy",
                    draft.text == "嗯"
                )
                check(
                    "A one-character copy reaches the store",
                    store.insert(draft)
                        && store.items.contains { $0.text == "嗯" }
                )
            } else {
                check(
                    "A one-character copy survives the capture policy",
                    false,
                    detail: "\(decision)"
                )
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaLimitTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            store.settings.historyLimit = 3
            store.settings.autoPauseAtLimit = true

            for index in 0..<3 {
                let text = "limit-\(index)"
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: text,
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: text)
                    )
                )
            }
            check(
                "Reaching the limit does not pause before the next capture",
                store.settings.pauseRecording == false
                    && store.items.count == 3
            )

            let duplicateAtLimit = store.insert(
                NewClip(
                    kind: .text,
                    text: "limit-2",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: "limit-2")
                )
            )
            check(
                "Duplicate touch is allowed at the auto-pause cap",
                duplicateAtLimit == false
                    && store.settings.pauseRecording == false
                    && store.items.count == 3
            )

            let paused = store.insert(
                NewClip(
                    kind: .text,
                    text: "blocked-over-limit",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: "blocked-over-limit")
                )
            )
            check(
                "Auto pause triggers once the rows reach the limit",
                !paused
                    && store.settings.pauseRecording == true
                    && store.items.count == 3
            )

            if let victim = store.items.first(where: { $0.text == "limit-0" }) {
                _ = store.delete(victim)
            }
            check(
                "Deleting a row resumes an auto-paused history",
                store.settings.pauseRecording == false
                    && store.settings.autoPausedByLimit == false
                    && store.items.count == 2
            )

            store.settings.autoPauseAtLimit = false
            store.settings.pauseRecording = false

            check(
                "Limit shrink asks only when rows would be deleted",
                SettingsStore.historyLimitDeletionCount(
                    current: 2000,
                    requested: 100,
                    rowCount: 445
                ) == 345
                    && SettingsStore.historyLimitDeletionCount(
                        current: 2000,
                        requested: 500,
                        rowCount: 445
                    ) == nil
                    && SettingsStore.historyLimitDeletionCount(
                        current: 500,
                        requested: 2000,
                        rowCount: 445
                    ) == nil
                    && SettingsStore.historyLimitDeletionCount(
                        current: 500,
                        requested: 0,
                        rowCount: 445
                    ) == nil
                    && SettingsStore.historyLimitDeletionCount(
                        current: 500,
                        requested: 500,
                        rowCount: 445
                    ) == nil

                    && SettingsStore.historyLimitDeletionCount(
                        current: 0,
                        requested: 2_000,
                        rowCount: 103_104
                    ) == 101_104
                    && SettingsStore.historyLimitDeletionCount(
                        current: 0,
                        requested: 2_000,
                        rowCount: 445
                    ) == nil
                    && SettingsStore.historyLimitDeletionCount(
                        current: 2_000,
                        requested: 0,
                        rowCount: 445
                    ) == nil
            )

            do {
                func decide(
                    _ status: SMAppService.Status,
                    wants: Bool = true,
                    identityMatches: Bool
                ) -> LaunchAtLoginAction {
                    SettingsStore.launchAtLoginAction(
                        status: status,
                        wantsLoginItem: wants,
                        identityMatchesRegistration: identityMatches
                    )
                }
                check(
                    "已登记且指纹一致 → 无事可做",
                    decide(.enabled, identityMatches: true) == .none
                )
                check(
                    "已登记但指纹变了（重装过）→ 重登记刷新记录",
                    decide(.enabled, identityMatches: false) == .refresh
                )
                check(
                    "未登记且指纹变了（重装后失效）→ 重新登记",
                    decide(.notRegistered, identityMatches: false) == .register
                )
                check(
                    "未登记但指纹没变 → 视作用户手动关闭，不抢",
                    decide(.notRegistered, identityMatches: true)
                        == .leaveForUser
                )
                check(
                    "系统要求批准 → 指到系统设置",
                    decide(.requiresApproval, identityMatches: false)
                        == .needsApproval
                )
                check(
                    "用户本来就不要自启 → 什么都不做",
                    decide(
                        .enabled,
                        wants: false,
                        identityMatches: false
                    ) == .none
                )

                let identityA = SettingsStore.currentBuildIdentity()
                let identityB = SettingsStore.currentBuildIdentity()
                check(
                    "bundle 指纹可读且稳定（64 位十六进制）",
                    identityA != nil && identityA == identityB
                        && identityA?.count == 64,
                    detail: "identity=\(identityA.map { String($0.prefix(8)) } ?? "nil")…"
                )
            }

            if let parsed = APIClientCLI.Options(
                arguments: ["search", "1", "limit", "50"]
            ) {
                check(
                    "search 的裸词全部拼进查询（少横杠的参数也一样）",
                    parsed.query == "1 limit 50" && parsed.limit == nil
                )
            } else {
                check("search 的裸词全部拼进查询", false)
            }

            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ClipSearchSortTest-\(UUID().uuidString)",
                        isDirectory: true
                    )
                let store = makeStore(dir)
                try MainActor.assumeIsolated {
                    let vm = PanelViewModel(store: store, settings: store.settings)
                    _ = store.insert(
                        NewClip(
                            kind: .text,
                            text: "sortrank",
                            sourceApp: "Test",
                            contentHash: ContentHasher.hash(text: "sortrank")
                        )
                    )
                    _ = store.insert(
                        NewClip(
                            kind: .text,
                            text: "sortrank-newer",
                            sourceApp: "Test",
                            contentHash: ContentHasher.hash(text: "sortrank-newer")
                        )
                    )
                    let firstText: () -> String? = {
                        vm.navigationOrder
                            .compactMap { store.clip(id: $0)?.text }.first
                    }
                    vm.query = "sortrank"
                    vm.queryDidChange()
                    let deadline = Date().addingTimeInterval(5)
                    while vm.navigationOrder.isEmpty, Date() < deadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                    }
                    check(
                        "相关排序把正文全等的排最前",
                        firstText() == "sortrank",
                        detail: "first=\(firstText() ?? "nil")"
                    )
                    vm.searchSort = .newest
                    let switchDeadline = Date().addingTimeInterval(5)
                    while firstText() != "sortrank-newer",
                          Date() < switchDeadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                    }
                    check(
                        "切到「最新」后按 lastCopiedAt 排（新插入的在前）",
                        firstText() == "sortrank-newer",
                        detail: "first=\(firstText() ?? "nil")"
                    )
                }
                try? FileManager.default.removeItem(at: dir)
            }

            for index in 0..<3 {
                let text = "shrink-limit-\(index)"
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: text,
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: text)
                    )
                )
            }
            let beforeShrink = store.historyCount
            store.settings.historyLimit = 2
            store.applyHistoryLimitNow()
            check(
                "Lowering the limit trims immediately",
                beforeShrink > 2 && store.historyCount == 2,
                detail: "\(beforeShrink) → \(store.historyCount)"
            )
            store.settings.historyLimit = 0

            let newestText = "newest-after-unlimited"
            let trimmedInsert = store.insert(
                NewClip(
                    kind: .text,
                    text: newestText,
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: newestText)
                )
            )
            check(
                "Trim keeps the newest rows and drops the oldest",
                trimmedInsert
                    && store.items.count == 3
                    && store.items.contains { $0.text == newestText }
            )

            let recencyOrdered: ([Clip]) -> Bool = { clips in
                zip(clips, clips.dropFirst()).allSatisfy { lhs, rhs in
                    lhs.lastCopiedAt != rhs.lastCopiedAt
                        ? lhs.lastCopiedAt > rhs.lastCopiedAt
                        : lhs.dbID > rhs.dbID
                }
            }
            if let target = store.items.first {
                _ = store.togglePrivate(target)
                _ = store.togglePrivate(target)
                _ = store.setNote("ordering-note", for: target)
                _ = store.setNote(nil, for: target)
            }
            check(
                "Metadata edits keep the in-memory recency order",
                recencyOrdered(store.items),
                detail: "\(store.items.count) rows"
            )

            let recopiedText = store.items.first?.text ?? ""
            let recopied = store.insert(
                NewClip(kind: .text, text: recopiedText, sourceApp: "Test")
            )
            check(
                "A duplicate re-copy moves its row to the front, order kept",
                !recopied
                    && store.items.first?.text == recopiedText
                    && recencyOrdered(store.items),
                detail: "first=\(store.items.first?.text ?? "nil")"
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipAssetAvailabilityTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            let missingImage = Clip(
                dbID: 1,
                id: UUID(),
                kind: .image,
                text: "",
                sourceApp: "Test",
                createdAt: Date(),
                lastCopiedAt: Date(),
                updatedAt: Date()
            )
            check(
                "Missing image reports unavailable",
                store.assetAvailability(for: missingImage) == .unavailable
            )

            let storedBytes = Data([1, 2, 3])
            _ = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: storedBytes,
                    imageFormat: "public.png",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(data: storedBytes)
                )
            )
            if let storedImage = store.items.first(where: {
                $0.kind == .image
            }) {
                check(
                    "Stored image reports available",
                    store.assetAvailability(for: storedImage) == .available
                )
            } else {
                check("Stored image fixture exists", false)
            }

            let missingFile = Clip(
                dbID: 3,
                id: UUID(),
                kind: .file,
                text: "",
                fileURLs: [
                    URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString).txt")
                ],
                sourceApp: "Test",
                createdAt: Date(),
                lastCopiedAt: Date(),
                updatedAt: Date()
            )
            let existingDirectoryFile = Clip(
                dbID: 4,
                id: UUID(),
                kind: .file,
                text: "",
                fileURLs: [dir],
                sourceApp: "Test",
                createdAt: Date(),
                lastCopiedAt: Date(),
                updatedAt: Date()
            )
            check(
                "Missing source file reports unavailable",
                store.assetAvailability(for: missingFile) == .unavailable
            )
            check(
                "Existing source path reports available",
                store.assetAvailability(for: existingDirectoryFile) == .available
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipImageAdoptionTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            let imageData = Data([0x89, 0x50, 0x4E, 0x47])
            let hash = ContentHasher.hash(data: imageData)
            _ = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: imageData,
                    imageFormat: "public.png",
                    sourceApp: "Test",
                    contentHash: hash
                )
            )
            if let existing = store.items.first,
               let database = store.database {

                _ = try? DatabaseSync.run(database) { db in
                    try await db.updateImage(
                        dbID: existing.dbID,
                        data: nil,
                        format: nil
                    )
                }
                let duplicated = store.insert(
                    NewClip(
                        kind: .image,
                        text: "",
                        imageData: imageData,
                        imageFormat: "public.png",
                        sourceApp: "Test",
                        contentHash: hash
                    )
                )
                let repaired = store.items.first
                check(
                    "Duplicate image re-adopts bytes when the row lost them",
                    duplicated == false
                        && store.items.count == 1
                        && repaired.map { store.imageData(for: $0) } == imageData
                )
            } else {
                check("Adoption fixture inserts image", false)
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipImageStorageTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            let databaseURL = DatabaseManager.databaseURL(in: dir)
            let imageBytes = Data((0..<4_096).map { UInt8($0 % 251) })
            _ = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: imageBytes,
                    imageFormat: "public.png",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(data: imageBytes)
                )
            )
            func rawCount(_ sql: String) -> Int? {
                guard let conn = try? DatabaseConnection(
                    path: databaseURL.path
                ) else { return nil }
                try? conn.configure()
                return try? conn.scalarInt(sql)
            }
            if let storedItem = store.items.first,
               let storeDatabase = store.database {
                check(
                    "Image bytes are stored in clip_images, not inline",
                    rawCount("SELECT COUNT(*) FROM clip_images") == 1
                        && rawCount(
                            "SELECT COUNT(*) FROM clips"
                                + " WHERE image_blob IS NOT NULL"
                        ) == 0
                        && store.imageData(for: storedItem) == imageBytes
                        && store.hasImageData(for: storedItem)
                )

                let legacyBytes = Data((0..<1_024).map { UInt8($0 % 97) })
                var legacyID: Int64 = 0
                if let conn = try? DatabaseConnection(path: databaseURL.path) {
                    try? conn.configure()
                    let stamp = Date().timeIntervalSince1970
                    let hex = legacyBytes
                        .map { String(format: "%02x", $0) }
                        .joined()
                    try? conn.exec("""
                        INSERT INTO clips (
                            id, kind, text, note, file_urls, source_app,
                            created_at, last_copied_at, updated_at,
                            is_pinned, is_private, is_hidden,
                            content_hash, smart_tag, image_blob, image_format
                        )
                        VALUES ('\(UUID().uuidString)', 3, '', '', '[]',
                                'Test', \(stamp), \(stamp), \(stamp),
                                0, 0, 0, NULL, 'image',
                                X'\(hex)', 'public.png')
                        """)
                    legacyID = Int64(
                        (try? conn.scalarInt(
                            "SELECT db_id FROM clips"
                                + " WHERE image_blob IS NOT NULL"
                        )) ?? 0
                    )
                }
                let migration = try? DatabaseSync.run(storeDatabase) { db in
                    try await db.migrateClipImages(limit: 10)
                }
                check(
                    "v10 image move rescues inline bytes",
                    legacyID > 0
                        && migration?.moved == 1
                        && migration?.remaining == 0
                        && rawCount(
                            "SELECT COUNT(*) FROM clips"
                                + " WHERE image_blob IS NOT NULL"
                        ) == 0
                )
                let migratedImage = try? DatabaseSync.run(storeDatabase) {
                    db in
                    try await db.imageData(dbID: legacyID)
                }
                check(
                    "Moved image is readable from the new table",
                    migratedImage == legacyBytes
                )

                _ = store.delete(ids: [storedItem.id])
                check(
                    "Deleting a clip removes its image row",
                    rawCount("SELECT COUNT(*) FROM clip_images") == 1
                )
                store.clearAll()
                check(
                    "Clearing history removes every image row",
                    rawCount("SELECT COUNT(*) FROM clip_images") == 0
                        && rawCount("SELECT COUNT(*) FROM clips") == 0
                )
            } else {
                check("Image storage fixture inserts", false)
            }
            try? FileManager.default.removeItem(at: dir)
        }

        check(
            "零宽字符与 BOM 归一化后消失",
            QueryNormalizer.normalize("cl\u{200B}i\u{200C}ck\u{200D}")
                == QueryNormalizer.normalize("click")
                && QueryNormalizer.normalize("a\u{FEFF}b") == "ab"
        )
        check(
            "NBSP 归一化为普通空格（分词可正常断词）",
            QueryNormalizer.normalize("alpha\u{00A0}beta") == "alpha beta"
        )

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipNormalizationFingerprintTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let original = "İSTANBUL Ağustos"
            let store = makeStore(dir)
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: original,
                    sourceApp: "Test"
                )
            )
            let databaseURL = DatabaseManager.databaseURL(in: dir)
            let expected = QueryNormalizer.normalize(original)
            var staleValue: String?
            if let conn = try? DatabaseConnection(path: databaseURL.path) {
                try? conn.configure()

                try? conn.exec("""
                    UPDATE clips
                    SET norm_text = 'stale-value', norm_note = 'stale-value'
                    """)
                try? conn.exec("""
                    INSERT OR REPLACE INTO store_meta (key, value)
                    VALUES ('search.normalized_text_version', '1')
                    """)
                staleValue = try? conn.prepare(
                    "SELECT norm_text FROM clips LIMIT 1"
                ) { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        return nil
                    }
                    return conn.columnText(statement, 0)
                } ?? nil
            }
            let reopened = makeStore(dir)
            var recomputed: String?
            var readyAfterReopen = false
            if let conn = try? DatabaseConnection(path: databaseURL.path) {
                try? conn.configure()
                recomputed = try? conn.prepare(
                    "SELECT norm_text FROM clips LIMIT 1"
                ) { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        return nil
                    }
                    return conn.columnText(statement, 0)
                } ?? nil
                readyAfterReopen = SearchRepository.isNormalizationComplete(
                    connection: conn
                )
            }
            check(
                "A normalization rule change recomputes existing rows",
                staleValue == "stale-value"
                    && recomputed == expected
                    && readyAfterReopen
                    && reopened.database != nil
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaWorkspaceTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            MainActor.assumeIsolated {
                let registry = WorkspaceStore(rootDirectory: root)
                check(
                    "A fresh workspace registry adopts the legacy database",
                    registry.workspaces.count == 1
                        && registry.activeWorkspace.isDefault
                        && registry.baseDirectory(
                            for: registry.activeWorkspace
                        ).path == root.path,
                    detail: registry.activeWorkspace.name
                )
                check(
                    "The default workspace cannot be deleted",
                    registry.canDeleteWorkspaces == false
                )

                let second = (try? registry.createWorkspace(named: "工作"))
                let third = (try? registry.createWorkspace(named: "工作"))
                check(
                    "New workspaces get their own directory and a unique name",
                    second != nil && third != nil
                        && second?.name == "工作"
                        && third?.name == "工作 2"
                        && registry.baseDirectory(for: second!)
                            .path != root.path
                        && FileManager.default.fileExists(
                            atPath: registry.baseDirectory(for: second!).path
                        )
                )

                if let second, let third {
                    let storeA = ClipStore(
                        baseDirectory: registry.baseDirectory(for: second)
                    )
                    _ = storeA.insert(
                        NewClip(
                            kind: .text,
                            text: "workspace-a-only",
                            sourceApp: "Test"
                        )
                    )
                    let storeB = ClipStore(
                        baseDirectory: registry.baseDirectory(for: third)
                    )
                    check(
                        "Clipboard history is isolated per workspace",
                        storeA.items.contains { $0.text == "workspace-a-only" }
                            && storeB.items.isEmpty,
                        detail: "A=\(storeA.items.count) B=\(storeB.items.count)"
                    )
                }

                try? registry.setActive(second!.id)
                try? registry.rename(second!.id, to: "工作区A")
                let reloaded = WorkspaceStore(rootDirectory: root)
                check(
                    "The active workspace and names survive a reload",
                    reloaded.workspaces.count == 3
                        && reloaded.activeID == second?.id
                        && reloaded.workspaces.contains { $0.name == "工作区A" }
                )
                check(
                    "The active workspace cannot be deleted",
                    reloaded.workspaces.contains(where: { $0.id == second?.id })
                )
                try? reloaded.delete(second!.id)
                check(
                    "The active workspace survives a delete request",
                    reloaded.workspaces.contains { $0.id == second?.id }
                )
                try? reloaded.delete(third!.id)
                check(
                    "A non-active workspace is removed from the registry",
                    !reloaded.workspaces.contains { $0.id == third?.id }
                )

                registry.setHistoryLimit(2000, for: second!.id)
                let reloadedLimits = WorkspaceStore(rootDirectory: root)
                check(
                    "A workspace's history limit survives a reload",
                    reloadedLimits.storedHistoryLimit(for: second!.id) == 2000
                )
                check(
                    "The default workspace keeps no limit of its own",
                    reloadedLimits.workspaces[0].isDefault
                        &&
                    reloadedLimits.storedHistoryLimit(
                        for: reloadedLimits.workspaces[0].id
                    ) == nil
                )
                let withLimit = try? registry.createWorkspace(
                    named: "带上限",
                    historyLimit: 300
                )
                check(
                    "A new workspace starts from the current limit",
                    withLimit?.historyLimit == 300
                )

                let scopeSuite = "ClipaHistoryLimitScope-\(UUID().uuidString)"
                let scopeDefaults = UserDefaults(suiteName: scopeSuite)!
                scopeDefaults.set(500, forKey: "historyLimit")
                let scoped = SettingsStore(
                    defaults: scopeDefaults

                )
                scoped.adoptHistoryLimit(1000, scope: .global)
                check(
                    "Adopting a limit never rewrites the scope being left",
                    scopeDefaults.integer(forKey: "historyLimit") == 500
                        && scoped.historyLimit == 1000
                )
                scoped.historyLimit = 300
                check(
                    "The global scope still writes the shared key",
                    scopeDefaults.integer(forKey: "historyLimit") == 300
                )
                let scratchID = UUID()
                var written: [(UUID, Int)] = []
                scoped.workspaceHistoryLimitWriter = { id, value in
                    written.append((id, value))
                }
                scoped.adoptHistoryLimit(
                    2000,
                    scope: .workspace(scratchID)
                )
                check(
                    "A workspace scope adopts that workspace's own value",
                    scoped.historyLimit == 2000
                )
                scoped.historyLimit = 100
                check(
                    "A workspace scope writes to the workspace, not the key",
                    written.count == 1
                        && written[0].0 == scratchID
                        && written[0].1 == 100
                        && scopeDefaults.integer(forKey: "historyLimit") == 300
                )
            }
            try? FileManager.default.removeItem(at: root)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipImageOrphanTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            store.settings.historyLimit = 1
            store.settings.autoPauseAtLimit = true
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: "occupies-limit",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: "occupies-limit")
                )
            )
            let bytes = Data([0x89, 0x50, 0x4E, 0x47])
            let inserted = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: bytes,
                    imageFormat: "public.png",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(data: bytes)
                )
            )
            check(
                "Auto-paused image capture is dropped",
                inserted == false
                    && store.items.count == 1
                    && !store.items.contains { $0.kind == .image }
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipImageBlobMigrationTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let imagesDir = dir.appendingPathComponent(
                "images",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(
                at: imagesDir,
                withIntermediateDirectories: true
            )
            let png = Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            )!
            try? png.write(to: imagesDir.appendingPathComponent("legacy.png"))

            let dbPath = dir.appendingPathComponent("clips.sqlite").path
            do {
                let conn = try DatabaseConnection(path: dbPath)
                try conn.configure()
                try conn.exec("""
                    CREATE TABLE clips (
                        db_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        id TEXT NOT NULL UNIQUE,
                        kind INTEGER NOT NULL,
                        text TEXT NOT NULL DEFAULT '',
                        note TEXT NOT NULL DEFAULT '',
                        image_file TEXT,
                        file_urls TEXT NOT NULL DEFAULT '[]',
                        source_app TEXT,
                        created_at REAL NOT NULL,
                        last_copied_at REAL,
                        updated_at REAL NOT NULL,
                        is_pinned INTEGER NOT NULL DEFAULT 0,
                        is_private INTEGER NOT NULL DEFAULT 0,
                        is_hidden INTEGER NOT NULL DEFAULT 0,
                        ai_visibility INTEGER NOT NULL DEFAULT 0,
                        content_hash TEXT,
                        smart_tag TEXT NOT NULL DEFAULT '',
                        classification_version INTEGER NOT NULL DEFAULT 0,
                        manual_tag TEXT,
                        contains_sensitive INTEGER NOT NULL DEFAULT 0
                    )
                    """)
                try conn.exec(DatabaseSchema.ftsTable)

                try conn.exec("""
                    CREATE TABLE ai_token_usage (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        timestamp REAL NOT NULL,
                        tokens INTEGER NOT NULL
                    )
                    """)
                let stamp = Date().timeIntervalSince1970
                try conn.exec("""
                    INSERT INTO clips (
                        id, kind, text, note, image_file,
                        created_at, last_copied_at, updated_at, smart_tag
                    ) VALUES (
                        '\(UUID().uuidString)', 3, '', '', 'legacy.png',
                        \(stamp), \(stamp), \(stamp), 'image'
                    )
                    """)
                try conn.exec("PRAGMA user_version = 6")
            } catch {
                check(
                    "v6 image fixture created",
                    false,
                    detail: error.localizedDescription
                )
            }

            let migratedStore = makeStore(dir)
            let pendingClip = migratedStore.items.first { $0.kind == .image }

            let deferred = pendingClip != nil
                && pendingClip.flatMap { migratedStore.imageData(for: $0) } == nil
                && FileManager.default.fileExists(atPath: imagesDir.path)
            _ = migratedStore.importLegacyImages()
            let imageClip = migratedStore.items.first { $0.kind == .image }
            let retired = FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(
                    "images-migrated-v6",
                    isDirectory: true
                ).path
            )
            check(
                "v6 image files migrate into BLOBs after launch",
                deferred
                    && imageClip != nil
                    && imageClip?.imageFormat == "public.png"
                    && imageClip.flatMap { migratedStore.imageData(for: $0) } == png
                    && retired
                    && !FileManager.default.fileExists(atPath: imagesDir.path)
            )

            let legacyAISchemaDropped: Bool = {
                guard let conn = try? DatabaseConnection(path: dbPath) else {
                    return false
                }
                try? conn.configure()
                return !conn.hasColumn(
                    table: "clips",
                    column: "ai_visibility"
                ) && !conn.hasTable("ai_token_usage")
            }()
            check(
                "Legacy AI schema (column + usage table) is dropped on upgrade",
                legacyAISchemaDropped
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipHashUniqueIndexTest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let dbPath = dir.appendingPathComponent("clips.sqlite").path
            do {
                let conn = try DatabaseConnection(path: dbPath)
                try conn.configure()
                try conn.exec(DatabaseSchema.clipsTable)
                try conn.exec(DatabaseSchema.clipsIndexes)
                try conn.exec(DatabaseSchema.ftsTable)
                try conn.exec("PRAGMA user_version = 5")
                let stamp = Date().timeIntervalSince1970
                try conn.exec("""
                    INSERT INTO clips (
                        id, kind, text, note, file_urls, source_app,
                        created_at, last_copied_at, updated_at,
                        is_pinned, is_private, is_hidden,
                        content_hash, smart_tag
                    )
                    VALUES
                    ('\(UUID().uuidString)', 0, 'dupe-before-index', '',
                     '[]', 'Test', \(stamp), \(stamp), \(stamp),
                     0, 0, 0, 'same-hash', 'text'),
                    ('\(UUID().uuidString)', 0, 'dupe-before-index', '',
                     '[]', 'Test', \(stamp), \(stamp), \(stamp),
                     1, 0, 0, 'same-hash', 'text')
                    """)
            } catch {
                check(
                    "Duplicate hash fixture created",
                    false,
                    detail: error.localizedDescription
                )
            }
            let store = makeStore(dir)
            check(
                "Legacy duplicate hash rows collapse before unique index",
                store.items.count == 1
                    && store.items.first?.text == "dupe-before-index"
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipHashKindTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            let path = "/tmp/clipa-fixture/report.pdf"
            let url = URL(fileURLWithPath: path)
            let fileDraft = NewClip(
                kind: .file,
                text: path,
                fileURLs: [url],
                sourceApp: "Finder",
                contentHash: ContentHasher.hash(fileURLs: [url])
            )
            let textDraft = NewClip(
                kind: .text,
                text: path,
                sourceApp: "终端",
                contentHash: ContentHasher.hash(text: path)
            )
            check(
                "A path and the file it names share one digest",
                fileDraft.contentHash != nil
                    && fileDraft.contentHash == textDraft.contentHash
            )
            _ = store.insert(fileDraft)
            _ = store.insert(textDraft)
            check(
                "The same digest with a different kind is a separate entry",
                store.items.count == 2,
                detail: "rows=\(store.items.count)"
            )
            check(
                "The text entry does not rewrite the file entry",
                store.items.filter { $0.text == path }.count == 2
                    && store.items.contains { $0.kind == .file }
                    && store.items.contains { $0.kind == .text },
                detail: store.items.map { $0.kind.rawValue }.joined(separator: ",")
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipLegacyImportRetryTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let jsonURL = dir.appendingPathComponent("clips.json")

            try? Data("{ not json".utf8).write(to: jsonURL)
            var firstLaunch: ClipStore? = makeStore(dir)
            check(
                "An undecodable legacy file imports nothing",
                firstLaunch?.items.isEmpty == true
            )
            firstLaunch = nil

            let legacyObject: [String: Any] = [
                "id": UUID().uuidString,
                "kind": "text",
                "text": "rescued legacy item",
                "fileURLs": [] as [String],
                "sourceApp": "Test",
                "createdAt": Date().timeIntervalSince1970,
                "updatedAt": Date().timeIntervalSince1970,
                "isPinned": false,
                "isHidden": false,
                "isPrivate": false
            ]
            if let jsonData = try? JSONSerialization.data(
                withJSONObject: [legacyObject],
                options: []
            ) {
                try? jsonData.write(to: jsonURL)
            }
            var secondLaunch: ClipStore? = makeStore(dir)
            check(
                "A legacy file that failed once is imported on a later launch",
                secondLaunch?.items.count == 1
                    && secondLaunch?.items.first?.text == "rescued legacy item",
                detail: "rows=\(secondLaunch?.items.count ?? -1)"
            )

            secondLaunch?.clearAll()
            secondLaunch = nil
            let thirdLaunch = makeStore(dir)
            check(
                "The legacy file is not re-imported after a successful import",
                thirdLaunch.items.isEmpty,
                detail: "rows=\(thirdLaunch.items.count)"
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipNulRoundTripTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            let text = "before\u{0}after"
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: text,
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: text)
                )
            )
            let loaded = store.items.first { $0.text.hasPrefix("before") }
            check(
                "A clip containing U+0000 round-trips intact",
                loaded?.text == text,
                detail: "read=\(loaded?.text.count ?? -1) chars, expected \(text.count)"
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipRetiredTableDropTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let databasePath = dir.appendingPathComponent("clips.sqlite")
            do {
                let conn = try DatabaseConnection(path: databasePath.path)
                try conn.configure()
                try conn.exec(DatabaseSchema.clipsTable)
                try conn.exec(DatabaseSchema.clipsIndexes)
                try conn.exec(DatabaseSchema.ftsTable)
                try conn.exec(DatabaseSchema.storeMetaTable)
                try conn.exec("CREATE TABLE search_learning (id INTEGER PRIMARY KEY)")
                try conn.exec("CREATE TABLE search_functions (id INTEGER PRIMARY KEY)")
                try conn.exec("PRAGMA user_version = 5")
                try StoreMeta.set(
                    "seeded",
                    forKey: "search_functions.examples_seeded.v4",
                    connection: conn
                )
                try StoreMeta.set(
                    "placeholder",
                    forKey: SearchRepository.normalizationMarkerKey,
                    connection: conn
                )
            } catch {
                check(
                    "Retired-table fixture created",
                    false,
                    detail: error.localizedDescription
                )
            }
            let upgraded = makeStore(dir)
            check("The upgraded store opens", upgraded.availability.isReady)
            if let conn = try? DatabaseConnection(path: databasePath.path) {
                check(
                    "Retired search tables are dropped on upgrade",
                    (try? conn.requireTable("search_learning")) == false
                        && (try? conn.requireTable("search_functions")) == false
                )
                check(
                    "Their store_meta bookkeeping is removed",
                    StoreMeta.value(
                        forKey: "search_functions.examples_seeded.v4",
                        connection: conn
                    ) == nil
                )
                check(
                    "The live normalization marker is not touched",
                    StoreMeta.value(
                        forKey: SearchRepository.normalizationMarkerKey,
                        connection: conn
                    ) != nil
                )
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaStoreFailure-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let databaseURL = DatabaseManager.databaseURL(in: dir)

            let freshStore = makeStore(dir)
            check(
                "Fresh install reports a ready store",
                freshStore.availability.isReady
                    && freshStore.items.isEmpty
            )
            try? FileManager.default.removeItem(at: dir)

            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let garbage = Data("not a sqlite database".utf8) + Data(repeating: 0, count: 4096)
            try? garbage.write(to: databaseURL)

            let brokenStore = makeStore(dir)
            check(
                "Corrupt database reports unavailable",
                brokenStore.availability.reason == .databaseUnreadable,
                detail: String(describing: brokenStore.availability)
            )
            check(
                "Unavailable store does not present an empty history as normal",
                !brokenStore.availability.isReady && brokenStore.items.isEmpty
            )
            check(
                "Unavailable store keeps the damaged file untouched",
                (try? Data(contentsOf: databaseURL)) == garbage
            )

            var rejectionNotices = 0
            let observer = NotificationCenter.default.addObserver(
                forName: ClipStore.captureRejectedNotification,
                object: brokenStore,
                queue: nil
            ) { _ in rejectionNotices += 1 }
            let text = "capture-while-unavailable"
            let inserted = brokenStore.insert(
                NewClip(
                    kind: .text,
                    text: text,
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: text)
                )
            )
            _ = brokenStore.insert(
                NewClip(
                    kind: .text,
                    text: "\(text)-2",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: "\(text)-2")
                )
            )
            check(
                "Unavailable store refuses captures",
                !inserted && brokenStore.items.isEmpty
            )
            check(
                "Rejection is explained once, not once per copy",
                rejectionNotices == 1,
                detail: "notices=\(rejectionNotices)"
            )
            NotificationCenter.default.removeObserver(observer)

            check(
                "Retry on a still-broken file stays unavailable",
                !brokenStore.retryDatabaseOpen()
                    && brokenStore.availability.reason == .databaseUnreadable
            )
            try? FileManager.default.removeItem(at: databaseURL)
            let recovered = brokenStore.retryDatabaseOpen()
            check(
                "Retry recovers after the path becomes usable",
                recovered
                    && brokenStore.availability.isReady
                    && brokenStore.database != nil
            )
            let afterRecovery = brokenStore.insert(
                NewClip(
                    kind: .text,
                    text: "capture-after-recovery",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(
                        text: "capture-after-recovery"
                    )
                )
            )
            check(
                "Captures resume after recovery",
                afterRecovery
                    && brokenStore.items.contains {
                        $0.text == "capture-after-recovery"
                    }
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let store = makeStore(
                URL(fileURLWithPath: "/dev/null/ClipaStoreFailure")
            )
            check(
                "Unwritable data directory reports a storage fault",
                store.availability.reason == .storageUnavailable,
                detail: String(describing: store.availability)
            )
        }

        do {
            let parser = SearchQuery.parse("docker network")
            check(
                "Parser splits whitespace AND terms",
                parser.terms.map(\.normalized) == ["docker", "network"]
            )

            let hybrid = SearchQuery.parse("docker AI")
            check(
                "Short terms stay memory-only",
                hybrid.ftsTerms.map(\.normalized) == ["docker"]
                    && hybrid.memoryTermStrings == ["docker", "ai"]
            )
            check(
                "FTS eligibility: long words yes, short tokens no",
                SearchQuery.canUseFTS(term: "docker")
                    && SearchQuery.canUseFTS(term: "网络配置")
                    && !SearchQuery.canUseFTS(term: "AI")
                    && !SearchQuery.canUseFTS(term: "C#")
            )
            check(
                "FTS builder escapes into quoted AND query",
                FTSQueryBuilder.buildANDQuery(terms: ["docker", "network"])
                    == "\"docker\" AND \"network\""
            )
            check(
                "FTS builder keeps sound partial groups for hybrid queries",
                FTSQueryBuilder.buildGroupQuery(
                    groups: [["docker"], ["ai"]]
                ) == "(\"docker\")"
                    && FTSQueryBuilder.buildGroupQuery(
                        groups: [["kubernetes"], ["网络"]]
                    ) == "(\"kubernetes\")"
                    && FTSQueryBuilder.buildGroupQuery(
                        groups: [["docker", "ai"]]
                    ) == nil
            )
            check(
                "Code/URL punctuation stays FTS-eligible",
                SearchQuery.canUseFTS(term: "192.168.1")
                    && FTSQueryBuilder.buildANDQuery(terms: ["192.168.1"])
                        == "\"192.168.1\""
            )

            let hybridDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaHybridTest-\(UUID().uuidString)", isDirectory: true)
            let hybridStore = makeStore(hybridDir)
            func draft(_ text: String, note: String? = nil) -> NewClip {
                NewClip(
                    kind: .text,
                    text: text,
                    note: note ?? text,
                    contentHash: ContentHasher.hash(text: text)
                )
            }
            hybridStore.insert(draft("docker ai workshop"))
            hybridStore.insert(draft("ai notes only"))
            let engine = hybridStore.database.map {
                LocalSearchEngine(database: $0)
            } ?? LocalSearchEngine()
            let hybridResult = engine.search(
                query: "docker AI",
                filter: SearchFilter(),
                store: hybridStore
            )
            check(
                "Hybrid query uses FTS for docker + memory for AI",
                hybridResult.clips.count == 1
                    && hybridResult.clips.first?.text == "docker ai workshop"
                    && (hybridResult.metrics?.candidateCount ?? 0) > 0
            )
            check(
                "SearchResponse exposes one ranked SearchResult per clip",
                hybridResult.results.map(\.clip.text) == hybridResult.clips.map(\.text)
                    && hybridResult.results.map(\.rank) == Array(hybridResult.clips.indices)
            )

            hybridStore.insert(draft("docker network bridge"))
            hybridStore.insert(draft("docker compose"))
            let multiResult = engine.search(
                query: "docker network",
                filter: SearchFilter(),
                store: hybridStore
            )
            check(
                "Multi-term query is one FTS AND query, memory-validated",
                multiResult.clips.count == 1
                    && multiResult.clips.first?.text == "docker network bridge"
            )
            hybridStore.insert(draft("ip 192.168.1.100"))
            let ipResult = engine.search(
                query: "192.168.1",
                filter: SearchFilter(),
                store: hybridStore
            )
            check(
                "Punctuation search runs through FTS",
                ipResult.clips.first?.text == "ip 192.168.1.100"
            )
            let noteResult = engine.search(
                query: "备注关键词",
                filter: SearchFilter(),
                store: hybridStore
            )
            check("Note-only search finds no body result", noteResult.clips.isEmpty)
            hybridStore.insert(
                NewClip(
                    kind: .text,
                    text: "无关正文",
                    note: "备注关键词 here",
                    contentHash: ContentHasher.hash(text: "无关正文")
                )
            )
            let noteHit = engine.search(
                query: "备注关键词",
                filter: SearchFilter(),
                store: hybridStore
            )
            check(
                "Note text participates in search",
                noteHit.clips.first?.note == "备注关键词 here"
            )
            hybridStore.insert(draft("更新备注测试正文"))
            if let updateTarget = hybridStore.items.first(
                where: { $0.text == "更新备注测试正文" }
            ) {
                _ = hybridStore.setNote("更新备注专用", for: updateTarget)
            }
            let updatedNoteResult = engine.search(
                query: "更新备注专用",
                filter: SearchFilter(),
                store: hybridStore
            )
            check(
                "Note update stays in sync with clips + clips_fts",
                updatedNoteResult.clips.first?.text == "更新备注测试正文"
            )

            let reordered = engine.search(
                query: "network docker",
                filter: SearchFilter(),
                store: hybridStore
            )
            check(
                "Multi-word search is order-independent AND, not one phrase",
                reordered.clips.count == 1
                    && reordered.clips.first?.text == "docker network bridge",
                detail: reordered.clips.map(\.text).joined(separator: " | ")
            )

            hybridStore.insert(draft("ＡＢＣ 全角文本"))
            hybridStore.insert(draft("café latte"))
            let fullWidth = engine.search(
                query: "abc",
                filter: SearchFilter(),
                store: hybridStore
            )
            check(
                "Full-width text is reachable from its half-width form",
                fullWidth.clips.contains { $0.text == "ＡＢＣ 全角文本" },
                detail: fullWidth.clips.map(\.text).joined(separator: " | ")
            )
            let unaccented = engine.search(
                query: "cafe",
                filter: SearchFilter(),
                store: hybridStore
            )
            check(
                "Accented text is reachable without the accent",
                unaccented.clips.contains { $0.text == "café latte" },
                detail: unaccented.clips.map(\.text).joined(separator: " | ")
            )
            try? FileManager.default.removeItem(at: hybridDir)

            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ClipFTSNormalizationTest-\(UUID().uuidString)", isDirectory: true)
                let store = makeStore(dir)
                let decomposedBody = "cafe\u{0301} compose"
                let composedBody = "café compose"
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: decomposedBody,
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: decomposedBody)
                    )
                )
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: composedBody,
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: composedBody)
                    )
                )
                let ftsEngine = LocalSearchEngine(
                    database: store.database,
                    store: store
                )
                let result = ftsEngine.search(
                    query: "café",
                    filter: SearchFilter(),
                    store: store
                )
                check(
                    "FTS normalization matches decomposed Unicode body",
                    result.clips.count == 2
                )
                let noteTarget = "normalized-note-target"
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: noteTarget,
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: noteTarget)
                    )
                )
                if let noteItem = store.items.first(
                    where: { $0.text == noteTarget }
                ) {
                    _ = store.setNote(
                        "cafe\u{0301} note",
                        for: noteItem
                    )
                }
                let noteResult = ftsEngine.search(
                    query: "café",
                    filter: SearchFilter(),
                    store: store
                )
                check(
                    "FTS note update matches decomposed Unicode note",
                    noteResult.clips.contains {
                        $0.text == noteTarget
                    }
                )
                try? FileManager.default.removeItem(at: dir)
            }

            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ClipFTSCandidateCapTest-\(UUID().uuidString)", isDirectory: true)
                let store = makeStore(dir)
                var drafts: [NewClip] = []
                for index in 0..<2001 {
                    let text = "capterm-\(index)"
                    drafts.append(
                        NewClip(
                            kind: .text,
                            text: text,
                            sourceApp: "Test",
                            contentHash: ContentHasher.hash(text: text)
                        )
                    )
                }
                store.replaceAllForTesting(drafts)
                let capEngine = LocalSearchEngine(
                    database: store.database,
                    store: store
                )
                let capResult = capEngine.search(
                    query: "capterm",
                    filter: SearchFilter(),
                    store: store
                )
                check(
                    "Truncated FTS recall falls back and finds old rows",
                    capResult.clips.count == 2001
                        && capResult.clips.contains {
                            $0.text == "capterm-2000"
                        }
                )
                try? FileManager.default.removeItem(at: dir)
            }

            var dbID: Int64 = 0
            func stub(
                text: String,
                note: String = "",
                ageDays: TimeInterval
            ) -> Clip {
                defer { dbID += 1 }
                let date = Date().addingTimeInterval(-ageDays * 86_400)
                return Clip(
                    dbID: dbID,
                    id: UUID(),
                    kind: .text,
                    text: text,
                    note: note,
                    createdAt: date,
                    lastCopiedAt: date,
                    updatedAt: date
                )
            }
            let exactOld = stub(text: "docker network", ageDays: 30)
            let fuzzyToday = stub(text: "docker compose network bridge", ageDays: 0)
            let query = SearchQuery.parse("docker network")
            let ranked = SearchRanker.rank(
                clips: [fuzzyToday, exactOld],
                query: query
            )
            check(
                "Exact old match outranks fuzzy fresh match",
                ranked.first?.text == "docker network"
            )

            let distributed = stub(
                text: "unrelated kubernetes",
                note: "docker unrelated",
                ageDays: 30
            )
            let notePhrase = stub(
                text: "unrelated body",
                note: "kubernetes docker",
                ageDays: 0
            )
            let planRanked = SearchRanker.rank(
                clips: [notePhrase, distributed],
                query: SearchQuery.parse("kubernetes docker"),
                groups: [["kubernetes"], ["docker"]]
            )
            check(
                "Multi-term plan ranks body/note distributed match above note-only",
                planRanked.first?.dbID == distributed.dbID
            )

            let today = stub(text: "today item", ageDays: 0)
            let yesterday = stub(text: "yesterday item", ageDays: 1)
            let groups = ClipGrouper.group(
                clips: [today, yesterday],
                calendar: .current
            )
            check(
                "Grouping buckets by recency",
                groups.map(\.section) == [.today, .yesterday]
            )

            let duplicateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaDuplicateTouchTest-\(UUID().uuidString)", isDirectory: true)
            let duplicateStore = makeStore(duplicateDir)
            func duplicateDraft(_ text: String) -> NewClip {
                NewClip(
                    kind: .text,
                    text: text,
                    contentHash: ContentHasher.hash(text: text)
                )
            }
            duplicateStore.insert(duplicateDraft("重复内容"))
            Thread.sleep(forTimeInterval: 1.05)
            duplicateStore.insert(duplicateDraft("另一条内容"))
            Thread.sleep(forTimeInterval: 1.05)
            duplicateStore.insert(duplicateDraft("重复内容"))
            let duplicateItems = duplicateStore.items
            check(
                "Duplicate touch keeps single row",
                duplicateItems.count == 2
            )
            if duplicateItems.count == 2 {
                check(
                    "Duplicate touch moves row back to top",
                    duplicateItems.first?.text == "重复内容"
                        && (duplicateItems.first?.lastCopiedAt ?? .distantPast)
                            > duplicateItems[1].lastCopiedAt
                )
            } else {
                check("Duplicate touch moves row back to top", false)
            }
            try? FileManager.default.removeItem(at: duplicateDir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaPrivateTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            store.insert(
                NewClip(
                    kind: .text,
                    text: "top secret token",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: "top secret token")
                )
            )
            _ = store.togglePrivate(store.items.first!)
            let reloaded = makeStore(dir)
            check("Private flag persists", reloaded.items.first?.isPrivate == true)
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            var nextDBID: Int64 = 0
            func item(
                _ text: String,
                kind: ClipKind = .text,
                source: String? = nil,
                date: Date = Date(),
                note: String = ""
            ) -> Clip {
                defer { nextDBID += 1 }
                return Clip(
                    dbID: nextDBID,
                    id: UUID(),
                    kind: kind,
                    text: text,
                    note: note,
                    sourceApp: source,
                    createdAt: date,
                    lastCopiedAt: date,
                    updatedAt: date,
                    smartTag: SmartClassifier.inferredTag(
                        text: text,
                        kind: kind
                    )
                )
            }
            let json = item(#"{"name":"Tom","age":18}"#, kind: .text)
            let yaml = item(
                """
                name: Tom
                age: 18
                city: Tokyo
                """,
                kind: .text
            )
            let ip = item("192.168.1.100")
            let email = item("user@example.com")
            let command = item("kubectl get pods -A", kind: .text)
            let url = item("https://github.com/openai/openai-python")
            let sensitive = item("sk-0123456789abcdef0123456789abcdef")
            let passwordSecret = item("password: hunter2hunter2")
            let accessToken = item("access_token = abcdefgh123456")

            check("Smart tag: JSON", json.smartTag == .json)
            check("Smart tag: YAML", yaml.smartTag == .yaml)
            let markdown = item(
                """
                # 网络配置说明

                下面列出常用命令：

                - docker network ls
                - docker network inspect
                """
            )
            check("Smart tag: Markdown", markdown.smartTag == .markdown)
            let logText = item(
                """
                2026-09-05 18:21:26 +0000 decode failed: 未能读取数据，因为它的格式不正确。
                raw: 不是 JSON
                2026-09-05 18:23:48 +0000 decode failed: 未能读取数据，因为它的格式不正确。
                raw: 不是 JSON
                """
            )
            check(
                "Log line is plain text, not YAML",
                logText.smartTag == .text
            )
            check("Smart tag: IPv4 stays text", ip.smartTag == .text)
            check("Smart tag: email stays text", email.smartTag == .text)
            check("Smart tag: command stays text", command.smartTag == .text)
            check("Smart tag: URL stays text", url.smartTag == .text)
            check("Sensitive detection", sensitive.isSensitiveContent && !command.isSensitiveContent)
            check(
                "Sensitive detection catches labeled passwords/tokens",
                passwordSecret.isSensitiveContent
                    && accessToken.isSensitiveContent
            )
            let commitHash = item(
                "0123456789abcdef0123456789abcdef01234567"
            )
            let shaLine = item(
                "sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            )
            check(
                "Sensitive detection ignores commit/SHA hashes",
                !commitHash.isSensitiveContent
                    && !shaLine.isSensitiveContent
            )
            check(
                "Sensitive detection ignores example password",
                !item("password: yourpassword123").isSensitiveContent
            )
            check(
                "Sensitive detection ignores example bearer",
                !item(
                    "Authorization: Bearer example-token-12345678"
                ).isSensitiveContent
            )
            check(
                "Sensitive detection ignores placeholder token",
                !item("token: example-token-123456").isSensitiveContent
            )

            check(
                "Sensitive detection reads quoted credential keys",
                item(#"{"password": "hunter2hunter2"}"#)
                    .isSensitiveContent
                    && item(#"{"api_key":"abcdefgh12345678"}"#)
                        .isSensitiveContent
                    && item(#""client_secret": "0123456789abcdef0123456789abcdef""#)
                        .isSensitiveContent
                    && item(#"password="hunter2hunter2""#)
                        .isSensitiveContent
                    && item(#"{"token":"9f8e7d6c5b4a39281706f5e4d3c2b1a0"}"#)
                        .isSensitiveContent
            )
            check(
                "Quoted placeholders and values stay safe",
                !item(#"{"password": "yourpassword123"}"#)
                    .isSensitiveContent
                    && !item(#"{"password": null}"#).isSensitiveContent
                    && !item(#"{"password": "abc"}"#).isSensitiveContent
            )

            let referenceForms = [
                #"password: ${DB_PASSWORD}"#,
                #"password: ${DB_PASSWORD:-}"#,
                #"password: ${DB_PASSWORD:=fallback}"#,
                #"password: $DB_PASSWORD"#,
                #"{"password": "@env:AC_PASSWORD"}"#,
                #"{"password": "[parameters('windowsAdminPassword')]"}"#,
                #"{"password": "${{ secrets.DB_PASSWORD }}"}"#,
                #"{"password": "{{ db_password }}"}"#
            ]
            check(
                "Reference and template values are not credentials",
                referenceForms.allSatisfy {
                    !item($0).isSensitiveContent
                },
                detail: referenceForms.filter {
                    item($0).isSensitiveContent
                }.joined(separator: " | ")
            )
            let cryptHashes = [
                #"password: $6$i3/J6tE.gh$ccHhabK2FsPT2U2OwMDiFZSPL7L18K"#,
                #"password: $y$j9T$21VgKI4Ug8Q/odUe/Tne31$6.0V1o7A4OJEjI8zXw9"#,
                #"password: $2b$12$K3JNi9YQ0mZ4v1Fq8Lx6AO"#,
                #"password: $argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ"#,
                #"password: $0$admin"#
            ]
            check(
                "Password hashes survive the reference downgrade",
                cryptHashes.allSatisfy { item($0).isSensitiveContent },
                detail: cryptHashes.filter {
                    !item($0).isSensitiveContent
                }.joined(separator: " | ")
            )
            check(
                "Mixed reference text is still a literal value",
                item(#"password: abc${REF}xyz123"#).isSensitiveContent
                    && item(#"password: hunter2hunter2"#).isSensitiveContent
                    && item(#"password: cisco123"#).isSensitiveContent
            )
            check(
                "SHA hashes stay unflagged by the sensitive rules",
                !SensitiveDetector.containsSensitive(
                    text: shaLine.text,
                    note: shaLine.note
                )
            )

            let gateSamples = [
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r",
                "postgres://admin:S3cret@db.internal:5432/app",
                "mongodb+srv://svc:Pa55w0rd@cluster0.example.net/db",
                "redis://default:foobared@cache.internal:6379",
                "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----"
            ]
            check(
                "Skip gate sees every rule the marker sees",
                gateSamples.allSatisfy {
                    SensitiveDetector.containsSensitive(text: $0)
                }
            )

            check("No misfire: go sentence", item("go to the store and get milk").smartTag == .text)
            check("No misfire: Python sentence", item("Python is a great language").smartTag == .text)
            check("No misfire: plain sentence", item("please run the deploy script.").smartTag == .text)
            check("No misfire: docker prose", item("docker is a tool for running containers").smartTag == .text)
            check("No misfire: npm prose", item("npm is a package manager").smartTag == .text)
            check("Command: python file stays text", item("python manage.py runserver").smartTag == .text)
            check("Command: python -m stays text", item("python3 -m http.server 8000").smartTag == .text)
            check("Command: go build stays text", item("go build ./cmd/app").smartTag == .text)
            check("Command: make build stays text", item("make build").smartTag == .text)
            check("Command: relative script stays text", item("./deploy.sh --prod").smartTag == .text)
            check("IP with port is not IP", item("10.0.1.20:8080").smartTag == .text)
            check("IP with CIDR stays text", item("192.168.1.0/24").smartTag == .text)
            check("Invalid CIDR is not IP", item("192.168.1.0/33").smartTag == .text)
            check("Invalid IPv6 is not IP", item("2001:db8::1::2").smartTag == .text)
            check("Email malformed domain", item("admin@example..com").smartTag == .text)
            check("Email unbalanced bracket", item("admin@example.com>").smartTag == .text)
            check("URL bare domain stays text", item("github.com/openai/openai-python").smartTag == .text)
            check("URL www stays text", item("www.apple.com").smartTag == .text)
            check("URL with query stays text", item("https://example.com/a?utm_source=x").smartTag == .text)
            check("No misfire: single-line colon note", item("时间: 下午三点").smartTag == .text)
            check(
                "No misfire: two-line note with one colon",
                item("说明: 出门\n记得带伞").smartTag == .text
            )
            check(
                "Single-line kind note is not YAML",
                item("kind: 说明").smartTag == .text
            )

            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ClipSmartTagLifecycleTest-\(UUID().uuidString)",
                        isDirectory: true
                    )
                let store = makeStore(dir)
                store.insert(
                    NewClip(
                        kind: .text,
                        text: "git status",
                        contentHash: ContentHasher.hash(text: "git status")
                    )
                )
                guard let command = store.items.first else {
                    check("Manual tag fixture inserted", false)
                    return Int32(failures)
                }
                check(
                    "DB stores consistent auto classification",
                    command.smartTag == .text
                        && command.kind == .text
                        && command.classificationVersion
                            == ClassificationPolicy.currentVersion
                        && command.smartTagIsManual == false
                )

                store.insert(
                    NewClip(
                        kind: .text,
                        text: "sk-0123456789abcdef0123456789abcdef",
                        contentHash: ContentHasher.hash(
                            text: "sk-0123456789abcdef0123456789abcdef"
                        )
                    )
                )
                check(
                    "Sensitive marker is precomputed at insert",
                    store.items.contains {
                        $0.smartTag == .text && $0.containsSensitive
                    }
                )

                if let database = store.database,
                   let target = store.items.first(
                    where: { $0.text == "git status" }
                   ) {
                    let downgraded: Clip? = awaitAsync {
                        try await database.setClassificationVersionForTesting(
                            dbID: target.dbID,
                            version: 0
                        )
                    } ?? nil
                    check(
                        "Reclassification fixture marked stale",
                        downgraded?.classificationVersion == 0
                    )

                    store.reloadFromDatabase()
                    check(
                        "Stale version is visible after reload",
                        store.items.first {
                            $0.text == "git status"
                        }?.classificationVersion == 0
                    )
                    _ = store.reclassifyPending(limit: 5)
                    check(
                        "Background reclassification upgrades stale row",
                        store.items.first {
                            $0.text == "git status"
                        }?.classificationVersion
                            == ClassificationPolicy.currentVersion
                    )
                } else {
                    check(
                        "Background reclassification upgrades stale row",
                        false
                    )
                }
                try? FileManager.default.removeItem(at: dir)
            }

            do {

                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ClipPrivateGuardTest-\(UUID().uuidString)",
                        isDirectory: true
                    )
                let store = makeStore(dir)
                store.insert(
                    NewClip(
                        kind: .text,
                        text: "private-guard-fixture",
                        contentHash: ContentHasher.hash(
                            text: "private-guard-fixture"
                        )
                    )
                )
                if let fixture = store.items.first(
                    where: { $0.text == "private-guard-fixture" }
                ), let database = store.database {
                    let sealed: Bool = awaitAsync {
                        (try? await database.updatePrivate(
                            dbID: fixture.dbID,
                            isPrivate: true
                        )) != nil
                    } ?? false
                    check(
                        "夹具先正常设为私密（真实加密路径）",
                        sealed
                    )
                    _ = awaitAsync {
                        try? await database.setStoredBodyForTesting(
                            dbID: fixture.dbID,
                            text: "clipa1:%%%invalid-envelope%%%"
                        )
                    }
                    let refused: Bool = awaitAsync {
                        do {
                            _ = try await database.updatePrivate(
                                dbID: fixture.dbID,
                                isPrivate: false
                            )
                            return false
                        } catch {
                            return true
                        }
                    } ?? false
                    check(
                        "解密失败的私密行拒绝取消私密（抛错而非写空串）",
                        refused
                    )
                    let storedAfter: String? = awaitAsync {
                        try? await database.storedBodyForTesting(
                            dbID: fixture.dbID
                        )
                    } ?? nil
                    check(
                        "密文仍在数据库里（没有被空串覆盖）",
                        storedAfter == "clipa1:%%%invalid-envelope%%%"
                    )

                    let recovered: Bool = awaitAsync {
                        do {
                            let good = try StoreCrypto.sealForStorage("recovered")
                            try await database.setStoredBodyForTesting(
                                dbID: fixture.dbID,
                                text: good
                            )
                            let updated = try await database.updatePrivate(
                                dbID: fixture.dbID,
                                isPrivate: false
                            )
                            return updated?.text == "recovered"
                        } catch {
                            return false
                        }
                    } ?? false
                    check(
                        "换成合法密文后同一切换成功（拒绝不是一刀切）",
                        recovered
                    )
                }
                try? FileManager.default.removeItem(at: dir)
            }

            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ClipSmartTagFilterTest-\(UUID().uuidString)",
                        isDirectory: true
                    )
                let store = makeStore(dir)
                store.insert(
                    NewClip(
                        kind: .text,
                        text: "name: nginx\nreplicas: 3",
                        contentHash: ContentHasher.hash(
                            text: "name: nginx\nreplicas: 3"
                        )
                    )
                )
                store.insert(
                    NewClip(
                        kind: .text,
                        text: "# 标题\n\n- 一\n- 二",
                        contentHash: ContentHasher.hash(
                            text: "# 标题\n\n- 一\n- 二"
                        )
                    )
                )
                let engine = LocalSearchEngine(
                    database: store.database,
                    store: store
                )
                let yamlOnly = engine.search(
                    query: "",
                    filter: SearchFilter(smartTags: [.yaml]),
                    store: store
                )
                let markdownOnly = engine.search(
                    query: "",
                    filter: SearchFilter(smartTags: [.markdown]),
                    store: store
                )
                check(
                    "SearchFilter supports smart tags end-to-end",
                    yamlOnly.clips.count == 1
                        && yamlOnly.clips.first?.smartTag == .yaml
                        && markdownOnly.clips.count == 1
                        && markdownOnly.clips.first?.smartTag == .markdown
                )
                try? FileManager.default.removeItem(at: dir)
            }

            let chrome = item(
                "kubernetes deployment rollback",
                kind: .text,
                source: "Chrome",
                note: "kubernetes deployment rollback"
            )
            var noted = item("部署上线", kind: .text)
            noted.note = "2026-09-04 备注"
            let searchIndex = MemorySearchIndex()
            searchIndex.rebuild(from: [
                chrome, noted, json, yaml, item("hello")
            ])
            func indexHit(_ clip: Clip, _ query: String) -> Bool {
                let terms = SearchQuery.parse(query).memoryTermStrings
                return searchIndex.containsAllTerms(
                    dbID: clip.dbID,
                    terms: terms
                )
            }
            check("Search: body token", indexHit(chrome, "kubernetes"))
            check("Search: note token", indexHit(noted, "备注"))
            check(
                "Search ignores source app",
                !indexHit(chrome, "chrome")
            )
            check("Search ignores type keyword", !indexHit(json, "json"))
            check("Search ignores yaml keyword", !indexHit(yaml, "yaml"))
            check("Search ignores time keyword",
                  !indexHit(item("hello"), "今天"))
            check(
                "Search: multi-token AND",
                !indexHit(chrome, "kubernetes chrome")
            )
            check("Search: negative token",
                  !indexHit(chrome, "image kubernetes"))

            do {
                let bulkCount = 40_000
                var bulk: [Clip] = []
                bulk.reserveCapacity(bulkCount)
                let bulkNow = Date()
                for value in 0..<bulkCount {
                    let text = value % 97 == 0
                        ? "needle 集群 \(value) 👨‍👩‍👧"
                        : "needle payload \(value) kubernetes 网络"
                    bulk.append(
                        Clip(
                            dbID: Int64(value + 1),
                            id: UUID(),
                            kind: .text,
                            text: text,
                            createdAt: bulkNow,
                            lastCopiedAt: bulkNow,
                            updatedAt: bulkNow
                        )
                    )
                }
                let bulkIndex = MemorySearchIndex()
                bulkIndex.rebuild(from: bulk)
                let expectedHits = Set(
                    bulk.filter { $0.text.contains("needle") }.map(\.dbID)
                )
                let indexedHits = Set(
                    bulkIndex.matchingIDs(
                        groups: [["needle"]],
                        excludedKeywords: []
                    )
                )
                check(
                    "Parallel index rebuild indexes every row",
                    bulkIndex.count == bulk.count
                        && indexedHits == expectedHits,
                    detail: "\(bulkIndex.count)/\(bulk.count) rows,"
                        + " \(indexedHits.count) hits"
                )
                let ambiguousExpected = Set(
                    bulk.filter { $0.text.contains("👨‍👩‍👧") }.map(\.dbID)
                )
                check(
                    "Parallel index rebuild keeps ambiguity flags",
                    !ambiguousExpected.isEmpty
                        && bulkIndex.ambiguousIDs == ambiguousExpected,
                    detail: "\(bulkIndex.ambiguousIDs.count)"
                        + " vs \(ambiguousExpected.count)"
                )
                check(
                    "Parallel index rebuild answers per-row lookups",
                    bulkIndex.containsAllTerms(
                        dbID: bulk[5_000].dbID,
                        terms: ["payload", "5000"]
                    ) && bulkIndex.normalizedFields(
                        dbID: bulk[5_000].dbID
                    ) != nil
                )
            }

            do {
                let stamp = Date()
                func indexedClip(_ dbID: Int64, _ text: String) -> Clip {
                    Clip(
                        dbID: dbID,
                        id: UUID(),
                        kind: .text,
                        text: text,
                        createdAt: stamp,
                        lastCopiedAt: stamp,
                        updatedAt: stamp
                    )
                }
                let index = MemorySearchIndex()
                index.rebuild(from: [
                    indexedClip(1, "alpha one"),
                    indexedClip(2, "beta two"),
                    indexedClip(3, "gamma three")
                ])
                var earlySnapshot: MemorySearchIndex? = index.snapshot()
                index.insert(clip: indexedClip(4, "delta four"))
                index.remove(dbID: 2)
                index.insert(clip: indexedClip(5, "emoji 👨‍👩‍👧 five"))

                let liveIDs = Set(
                    index.matchingIDs(
                        groups: [["alpha", "beta", "delta", "emoji"]],
                        excludedKeywords: []
                    )
                )
                check(
                    "Deferred changes are visible to the live index",
                    liveIDs == [1, 4, 5]
                        && index.normalizedFields(dbID: 2) == nil
                        && index.normalizedFields(dbID: 4) != nil
                        && index.normalizedFields(dbID: 5) != nil
                        && index.count == 4
                )
                check(
                    "Deferred changes gate the SQL fast path",
                    index.isCanonicallyAmbiguous(dbID: 5)
                        && index.hasAmbiguousRows
                        && index.ambiguousRowCount == 1
                        && index.effectiveAmbiguousIDs == [5]
                )
                let earlyIDs = Set(
                    earlySnapshot?.matchingIDs(
                        groups: [["alpha", "beta", "delta", "emoji"]],
                        excludedKeywords: []
                    ) ?? []
                )
                check(
                    "A snapshot taken earlier keeps its own view",
                    earlyIDs == [1, 2]
                        && earlySnapshot?.normalizedFields(dbID: 4) == nil
                        && earlySnapshot?.normalizedFields(dbID: 2) != nil
                )
                var laterSnapshot: MemorySearchIndex? = index.snapshot()
                check(
                    "A snapshot taken later sees the queued changes",
                    Set(
                        laterSnapshot?.matchingIDs(
                            groups: [["alpha", "delta", "emoji"]],
                            excludedKeywords: []
                        ) ?? []
                    ) == [1, 4, 5]
                        && laterSnapshot?.isCanonicallyAmbiguous(
                            dbID: 5
                        ) == true
                )

                earlySnapshot = nil
                laterSnapshot = nil
                index.remove(dbID: 1)
                let afterMerge = Set(
                    index.matchingIDs(
                        groups: [["alpha", "delta", "emoji"]],
                        excludedKeywords: []
                    )
                )
                check(
                    "Queued changes survive the merge into the base index",
                    afterMerge == [4, 5]
                        && index.count == 3
                        && index.normalizedFields(dbID: 3) != nil
                        && index.ambiguousRowCount == 1
                )
            }

            do {
                let base = Date()
                func timeCriteria(_ interval: DateInterval?) -> SearchCriteria {
                    SearchCriteria(
                        plan: SearchQueryPlan(
                            originalQuery: "time",
                            keywordGroups: [],
                            excludedKeywords: [],
                            timeRange: interval,
                            kinds: [],
                            smartTags: [],
                            sort: .relevance,
                            limit: nil
                        )
                    )
                }
                func timeClip(_ offset: TimeInterval) -> Clip {
                    Clip(
                        dbID: 1,
                        id: UUID(),
                        kind: .text,
                        text: "time",
                        createdAt: base,
                        lastCopiedAt: base.addingTimeInterval(offset),
                        updatedAt: base
                    )
                }
                let window = timeCriteria(
                    DateInterval(start: base, duration: 60)
                )
                check(
                    "Time filter keeps the ±1s storage tolerance",
                    window.matches(clip: timeClip(-0.5))
                        && window.matches(clip: timeClip(60.5))
                        && !window.matches(clip: timeClip(-1.5))
                        && !window.matches(clip: timeClip(61.5))
                )

            }

            do {
                let base = Date()
                func windowedPlan(_ range: DateInterval?) -> SearchQueryPlan {
                    SearchQueryPlan(
                        originalQuery: "deploy",
                        keywordGroups: [["deploy"]],
                        excludedKeywords: [],
                        timeRange: range,
                        kinds: [],
                        smartTags: [],
                        sort: .relevance,
                        limit: nil
                    )
                }
                func timeClip(_ offset: TimeInterval) -> Clip {
                    Clip(
                        dbID: 1,
                        id: UUID(),
                        kind: .text,
                        text: "deploy",
                        createdAt: base,
                        lastCopiedAt: base.addingTimeInterval(offset),
                        updatedAt: base
                    )
                }
                let planWindow = DateInterval(start: base, duration: 3_600)
                let disjoint = SearchCriteria(
                    plan: windowedPlan(planWindow),
                    filter: SearchFilter(
                        timeRange: DateInterval(
                            start: base.addingTimeInterval(7_200),
                            duration: 3_600
                        )
                    )
                )
                check(
                    "Disjoint time ranges match nothing instead of trapping",
                    !disjoint.matches(clip: timeClip(0))
                        && !disjoint.matches(clip: timeClip(7_500))
                )
                let overlapping = SearchCriteria(
                    plan: windowedPlan(planWindow),
                    filter: SearchFilter(
                        timeRange: DateInterval(
                            start: base.addingTimeInterval(1_800),
                            duration: 3_600
                        )
                    )
                )
                check(
                    "Overlapping ranges keep the tighter window",
                    overlapping.matches(clip: timeClip(2_400))
                        && !overlapping.matches(clip: timeClip(600))
                )
                let unsatisfiable = SearchCriteria(
                    plan: SearchQueryPlan(
                        originalQuery: "deploy",
                        keywordGroups: [["deploy"]],
                        excludedKeywords: [],
                        timeRange: planWindow,
                        kinds: [],
                        smartTags: [],
                        sort: .relevance,
                        limit: nil,
                        isUnsatisfiable: true
                    )
                )
                check(
                    "A plan marked unsatisfiable matches nothing",
                    !unsatisfiable.matches(clip: timeClip(0))
                )
            }

            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ClipListWindowTest-\(UUID().uuidString)",
                        isDirectory: true
                    )
                let store = makeStore(dir)
                store.settings.historyLimit = 0
                _ = store.replaceAllForTesting(
                    (0..<1_200).map { index in
                        NewClip(
                            kind: .text,
                            text: "window-row-\(index)",
                            sourceApp: "Test"
                        )
                    }
                )
                MainActor.assumeIsolated {
                    let vm = PanelViewModel(
                        store: store,
                        settings: store.settings
                    )
                    vm.refreshSearch()
                    let page = PanelViewModel.listWindowPageSize
                    check(
                        "Windowed list hands the view one page, not every row",
                        vm.navigationOrder.count == 1_200
                            && vm.listEntries.count > 1_200
                            && vm.renderedEntries.count <= page
                            && vm.canExtendRenderedWindow
                    )
                    vm.extendRenderedWindow()
                    check(
                        "Scrolling extends the window by one page",
                        vm.renderedEntries.count > page
                            && vm.renderedEntries.count <= page * 2
                    )
                    let lastID = vm.navigationOrder.last!
                    vm.ensureEntryVisible(clipID: lastID)
                    check(
                        "A far jump keeps its row inside the window",
                        vm.renderedEntries.contains {
                            $0.id == "clip-\(lastID.uuidString)"
                        } && vm.renderedEntries.count <= page + 1
                    )

                    check(
                        "A recentred window can be scrolled back upwards",
                        vm.canExtendRenderedWindowUpward
                    )
                    check(
                        "Counts still describe the whole result set",
                        vm.navigationOrder.count == 1_200
                            && vm.listEntries.count > vm.renderedEntries.count
                    )
                    var coveredTop = false
                    for _ in 0..<40 {
                        vm.extendRenderedWindowUpward()
                        if !vm.canExtendRenderedWindowUpward {
                            coveredTop = true
                            break
                        }
                    }
                    check(
                        "Scrolling up reaches the first row again",
                        coveredTop
                            && vm.renderedEntries.first?.id
                                == vm.listEntries.first?.id
                    )
                }
                try? FileManager.default.removeItem(at: dir)
            }

        }

        check(
            "FTS group query quotes AND/OR",
            FTSQueryBuilder.buildGroupQuery(
                groups: [["kubernetes"], ["network"]]
            ) == "(\"kubernetes\") AND (\"network\")"
                && FTSQueryBuilder.buildGroupQuery(
                    groups: [["terway", "cilium"]]
                ) == "(\"terway\" OR \"cilium\")"
        )

        do {
            let item = Clip(
                dbID: 1,
                id: UUID(),
                kind: .text,
                text: "paste-copy-test-\(UUID().uuidString)",
                sourceApp: nil,
                createdAt: Date(),
                lastCopiedAt: Date(),
                updatedAt: Date()
            )
            let original = ClipboardWriter.PasteboardSnapshot.current()
            let wrote = ClipboardWriter.shared.copy(item)
            check(
                "Copy writes to pasteboard and reports success",
                wrote
                    && NSPasteboard.general.string(forType: .string) == item.text
            )
            if let original {
                original.restore()
                ClipboardMonitor.shared.resetChangeCount()
            }
        }

        do {
            let isolated = NSPasteboard(
                name: NSPasteboard.Name("ClipaCopyFailureTest-\(UUID().uuidString)")
            )
            isolated.clearContents()
            let missingImage = Clip(
                dbID: 9001,
                id: UUID(),
                kind: .image,
                text: "",
                sourceApp: nil,
                createdAt: Date(),
                lastCopiedAt: Date(),
                updatedAt: Date()
            )
            let failed = ClipboardWriter.shared.copy(missingImage, to: isolated)
            check(
                "Missing image copy returns failure",
                !failed
                    && isolated.data(forType: .png) == nil
            )
        }

        do {
            let isolated = NSPasteboard(
                name: NSPasteboard.Name("ClipaMissingFileCopyTest-\(UUID().uuidString)")
            )
            isolated.clearContents()
            let missingFile = Clip(
                dbID: 9002,
                id: UUID(),
                kind: .file,
                text: "",
                fileURLs: [
                    URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString).txt")
                ],
                sourceApp: nil,
                createdAt: Date(),
                lastCopiedAt: Date(),
                updatedAt: Date()
            )
            let failed = ClipboardWriter.shared.copy(missingFile, to: isolated)
            check(
                "Missing source file copy returns failure",
                !failed
                    && isolated.data(forType: .fileURL) == nil
            )
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipDeleteResultTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            let text = "delete-result-check"
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: text,
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(text: text)
                )
            )
            if let item = store.items.first {
                check(
                    "Delete reports one removed row",
                    store.delete(item) == .deleted(count: 1)
                        && store.items.isEmpty
                )
                check(
                    "Repeated delete reports zero, not success",
                    store.delete(item) == .deleted(count: 0)
                )
            } else {
                check("Delete result fixture exists", false)
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipCopyFailureToastTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            let bytes = Data([9, 9, 9])
            _ = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: bytes,
                    imageFormat: "public.png",
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(data: bytes)
                )
            )
            if let item = store.items.first {

                if let database = store.database {
                    _ = try? DatabaseSync.run(database) { db in
                        try await db.updateImage(
                            dbID: item.dbID,
                            data: nil,
                            format: nil
                        )
                    }
                }
                MainActor.assumeIsolated {
                    let vm = PanelViewModel(
                        store: store,
                        settings: store.settings
                    )
                    vm.copy(item)
                    check(
                        "Copy failure shows failure toast, not success",
                        vm.toast?.contains("图片数据缺失") == true
                    )
                }
            } else {
                check("Copy failure fixture exists", false)
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipMissingFileToastTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            let missingPath = "/tmp/missing-\(UUID().uuidString).txt"
            _ = store.insert(
                NewClip(
                    kind: .file,
                    text: missingPath,
                    fileURLs: [URL(fileURLWithPath: missingPath)],
                    sourceApp: "Test",
                    contentHash: ContentHasher.hash(fileURLs: [
                        URL(fileURLWithPath: missingPath)
                    ])
                )
            )
            if let item = store.items.first {
                MainActor.assumeIsolated {
                    let vm = PanelViewModel(
                        store: store,
                        settings: store.settings
                    )
                    vm.copy(item)
                    check(
                        "Missing file copy shows failure toast, not success",
                        vm.toast?.contains("文件已被移动或删除") == true
                    )
                }
            } else {
                check("Missing file toast fixture exists", false)
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaNavigationTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            for index in 0..<4 {
                store.insert(
                    NewClip(
                        kind: .text,
                        text: "navigation-row-\(index)",
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: "navigation-row-\(index)")
                    )
                )
            }
            MainActor.assumeIsolated {
                let vm = PanelViewModel(
                    store: store,
                    settings: store.settings
                )

                vm.refreshSearch()
                check(
                    "Navigation has flat row order",
                    vm.navigationOrder.count == 4,
                    detail: "count=\(vm.navigationOrder.count)"
                )
                check(
                    "PanelViewModel exposes flat clips",
                    vm.clips.count == 4 && vm.searchState == .idle
                )
                let firstID = vm.navigationOrder.first
                if let firstID,
                   let firstClip = store.clip(id: firstID) {
                    vm.select(firstClip)
                }
                vm.moveSelection(by: 1)
                let secondID = vm.selectedItem?.id
                check(
                    "Arrow down moves selection",
                    secondID != nil && secondID != firstID
                        && vm.navigationOrder.contains(secondID!)
                )
                vm.moveSelection(by: 1)
                vm.moveSelection(by: 1)
                vm.moveSelection(by: 1)
                check(
                    "Arrow wrap-around returns to start",
                    vm.selectedItem?.id == firstID
                )
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipSelectionReconcileTest-\(UUID().uuidString)", isDirectory: true)
            let store = makeStore(dir)
            for index in 0..<2 {
                let text = "selection-row-\(index)"
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: text,
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: text)
                    )
                )
            }
            MainActor.assumeIsolated {
                let vm = PanelViewModel(
                    store: store,
                    settings: store.settings
                )
                vm.refreshSearch()
                guard let first = vm.clips.first else {
                    check("Selection reconcile fixture exists", false)
                    return
                }
                vm.select(first)
                check(
                    "Re-query keeps the visible row selected",
                    vm.selectedItem?.id == first.id
                )

                vm.query = "selection-row-none"
                vm.refreshSearch()
                check(
                    "A selection that leaves the result set is cleared",
                    vm.navigationOrder.isEmpty
                        && vm.selectedItem == nil
                )
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipDeleteKeepsPlace-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            for index in 0..<5 {
                let text = "delete-place-\(index)"
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: text,
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: text)
                    )
                )
            }
            MainActor.assumeIsolated {
                let vm = PanelViewModel(store: store, settings: store.settings)
                vm.refreshSearch()
                let order = vm.navigationOrder
                guard order.count == 5, let third = store.clip(id: order[2]) else {
                    check("Delete keeps place: fixture rows exist", false)
                    return
                }
                vm.select(third)
                check(
                    "Delete keeps place: selecting a card asks the row to follow",
                    vm.revealSelection
                )

                Task { @MainActor in await vm.deleteAsync(third) }
                var deleteDeadline = Date().addingTimeInterval(10)
                while vm.navigationOrder.count == 5, Date() < deleteDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Delete keeps place: the next card takes the selection",
                    vm.navigationOrder.count == 4
                        && vm.selectedItem?.id == order[3],
                    detail: vm.selectedItem?.text ?? "nil"
                )
                check(
                    "Delete keeps place: the row does not scroll after a delete",
                    !vm.revealSelection
                )

                vm.moveSelection(by: 1)
                check(
                    "Delete keeps place: navigating again restores following",
                    vm.revealSelection
                )
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let ready = PanelKeyRouter(
                isTextEditorOpen: false,
                isComposingText: false
            )
            check(
                "Return copies the selected clip while the search field is focused",
                ready.action(keyCode: 36, modifiers: []) == .copySelected
            )
            check(
                "Keypad Enter copies as well",
                ready.action(keyCode: 76, modifiers: []) == .copySelected
            )
            check(
                "Arrows still move the selection from the search field",
                ready.action(keyCode: 126, modifiers: []) == .moveSelection(-1)
                    && ready.action(keyCode: 125, modifiers: []) == .moveSelection(1)
            )

            check(
                "Command-D passes through",
                ready.action(keyCode: 2, modifiers: [.command]) == .passThrough
                    && ready.action(keyCode: 2, modifiers: []) == .passThrough
            )
            check(
                "Return mid input-method composition belongs to the IME",
                PanelKeyRouter(
                    isTextEditorOpen: false,
                    isComposingText: true
                ).action(keyCode: 36, modifiers: []) == .passThrough
            )
            let editing = PanelKeyRouter(
                isTextEditorOpen: true,
                isComposingText: false
            )
            check(
                "Return inside the note or snippet editor stays with the editor",
                editing.action(keyCode: 36, modifiers: []) == .passThrough
                    && editing.action(keyCode: 126, modifiers: []) == .passThrough
            )
            check(
                "Unrelated keys pass through",
                ready.action(keyCode: 0, modifiers: []) == .passThrough
            )

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipSelectionDefaultTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            for index in 0..<2 {
                let text = "selection-default-\(index)"
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: text,
                        sourceApp: "Test",
                        contentHash: ContentHasher.hash(text: text)
                    )
                )
            }
            MainActor.assumeIsolated {
                let vm = PanelViewModel(
                    store: store,
                    settings: store.settings
                )
                vm.selectedID = nil
                vm.refreshSearch()
                check(
                    "A visible list without a selection adopts the first row",
                    vm.selectedItem?.id == vm.navigationOrder.first
                )
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let own = "com.clipa.desktop"
            let xcode = IgnoreTargetResolver.Candidate(
                bundleID: "com.apple.dt.Xcode",
                name: "Xcode"
            )
            let clipa = IgnoreTargetResolver.Candidate(
                bundleID: own,
                name: "Clipa"
            )
            let safari = IgnoreTargetResolver.Candidate(
                bundleID: "com.apple.Safari",
                name: "Safari"
            )
            check(
                "A frontmost external app is the ignore target",
                IgnoreTargetResolver.resolve(
                    frontmost: xcode,
                    lastExternal: nil,
                    ownBundleID: own
                ) == .resolved(bundleID: "com.apple.dt.xcode", name: "Xcode")
            )
            check(
                "Clipa frontmost falls back to the last app the user worked in",
                IgnoreTargetResolver.resolve(
                    frontmost: clipa,
                    lastExternal: xcode,
                    ownBundleID: own
                ) == .resolved(bundleID: "com.apple.dt.xcode", name: "Xcode")
            )
            check(
                "Clipa frontmost with no known external app is unavailable",
                IgnoreTargetResolver.resolve(
                    frontmost: clipa,
                    lastExternal: nil,
                    ownBundleID: own
                ) == .unavailable
            )
            check(
                "A stale Clipa entry is never used as the external app",
                IgnoreTargetResolver.resolve(
                    frontmost: clipa,
                    lastExternal: clipa,
                    ownBundleID: own
                ) == .unavailable
            )
            check(
                "No frontmost app falls back to the last external app",
                IgnoreTargetResolver.resolve(
                    frontmost: nil,
                    lastExternal: safari,
                    ownBundleID: own
                ) == .resolved(bundleID: "com.apple.safari", name: "Safari")
            )
            check(
                "An app without a bundle id cannot be ignored",
                IgnoreTargetResolver.resolve(
                    frontmost: IgnoreTargetResolver.Candidate(
                        bundleID: nil,
                        name: "helper"
                    ),
                    lastExternal: nil,
                    ownBundleID: own
                ) == .missingBundleID(name: "helper")
            )
            check(
                "Unavailable resolution carries an explanation",
                IgnoreTargetResolution.unavailable.failureMessage?.isEmpty
                    == false
                    && IgnoreTargetResolution.resolved(
                        bundleID: "com.apple.Safari",
                        name: "Safari"
                    ).failureMessage == nil
            )
        }

        do {
            let suite = "ClipaIgnorePolicy-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "ignorePasswordManagers")
            let settings = SettingsStore(defaults: defaults)
            settings.ignoredApps = ["com.example.secret"]
            let policy = CapturePolicySnapshot(settings: settings)
            let ownAppDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaOwnAppPolicy-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: ownAppDir,
                withIntermediateDirectories: true
            )
            let ownAppStore = ClipStore(
                baseDirectory: ownAppDir,
                settingsStore: settings
            )

            check(
                "A single known-ignored app is refused",
                policy.ignores(anyOf: ["com.example.secret"])
            )
            check(
                "An ignored app anywhere in the poll window is refused",
                policy.ignores(
                    anyOf: ["com.apple.Safari", "com.example.secret", nil]
                )
            )
            check(
                "Unknown apps are not treated as ignored",
                !policy.ignores(anyOf: ["com.apple.Safari", nil, nil])
            )
            check(
                "Own-app detection matches Clipa only, and never a foreign app",
                !policy.isOwnApp(bundleID: "com.apple.Safari")
                    && (policy.ownBundleID == nil
                        ? !policy.isOwnApp(bundleID: nil)
                        : policy.isOwnApp(bundleID: policy.ownBundleID))
            )

            let scratch = NSPasteboard(
                name: NSPasteboard.Name("clipa-own-app-check")
            )
            scratch.clearContents()
            scratch.setString(
                "own-app-attribution-probe",
                forType: .string
            )
            let ownDecision = ClipboardMonitor.shared.evaluate(
                pasteboard: scratch,
                frontBundleID: policy.ownBundleID ?? "com.clipa.desktop",
                sourceName: "终端",
                settings: settings,
                store: ownAppStore
            )
            let ownCaptured: String? = {
                if case .captured(let draft) = ownDecision {
                    return draft.text
                }
                return nil
            }()
            check(
                "A copy made while Clipa is frontmost is not dropped as own-app",
                ownCaptured == "own-app-attribution-probe",
                detail: ownCaptured ?? "\(ownDecision)"
            )

            let segment = ActiveAppTracker.FrontmostSegment(
                bundleID: "com.clipa.desktop",
                name: "Clipa",
                startedAt: Date()
            )
            check(
                "Attribution falls back to the last external app",
                ClipboardMonitor.captureSource(
                    owners: [segment],
                    isOwnApp: { $0 == "com.clipa.desktop" },
                    lastExternalName: "终端"
                ) == (name: "终端", bundleID: nil)
            )

            check(
                "Attribution carries the external app's bundle ID",
                ClipboardMonitor.captureSource(
                    owners: [
                        segment,
                        ActiveAppTracker.FrontmostSegment(
                            bundleID: "com.apple.Safari",
                            name: "Safari",
                            startedAt: Date()
                        )
                    ],
                    isOwnApp: { $0 == "com.clipa.desktop" },
                    lastExternalName: "终端"
                ) == (name: "Safari", bundleID: "com.apple.Safari")
            )

            let tracker = ActiveAppTracker.shared
            let base = Date()
            tracker.record(bundleID: "com.example.secret", name: "Secret", at: base)
            tracker.record(
                bundleID: "com.apple.Safari",
                name: "Safari",
                at: base.addingTimeInterval(0.2)
            )
            let window = tracker.frontmostSince(
                base.addingTimeInterval(0.1),
                now: base.addingTimeInterval(0.25)
            )
            check(
                "The app covering the window start stays in the candidates",
                window.count == 2
                    && window.first?.bundleID == "com.example.secret"
                    && window.last?.bundleID == "com.apple.Safari",
                detail: String(describing: window.map(\.bundleID))
            )
            check(
                "A window inside one app reports only that app",
                tracker.frontmostSince(
                    base.addingTimeInterval(0.21),
                    now: base.addingTimeInterval(0.25)
                ).map(\.bundleID) == ["com.apple.Safari"]
            )
            check(
                "Copying in an ignored app then switching still drops the capture",
                policy.ignores(anyOf: window.map(\.bundleID))
            )
        }

        do {
            check(
                "Bundle ids are trimmed and lowercased",
                BundleIDNormalizer.normalize("  Com.Apple.Safari \n")
                    == "com.apple.safari"
            )
            check(
                "Blank bundle ids are dropped",
                BundleIDNormalizer.normalize("   ") == nil
                    && BundleIDNormalizer.normalize(["", "a", "  "]) == ["a"]
            )
            check(
                "Normalizing keeps order and removes duplicates",
                BundleIDNormalizer.normalize(
                    ["Com.B", "com.a", "COM.B", ""]
                ) == ["com.b", "com.a"]
            )

            let suite = "ClipaIgnoreNormalize-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(
                try? JSONEncoder().encode(
                    ["  Com.Apple.Safari ", "com.apple.safari", ""]
                ),
                forKey: "ignoredApps"
            )
            let settings = SettingsStore(defaults: defaults)
            check(
                "Legacy entries are normalized on load",
                settings.ignoredApps == ["com.apple.safari"]
            )
            check(
                "Matching ignores case and surrounding whitespace",
                settings.isIgnored(bundleID: "COM.APPLE.SAFARI")
                    && settings.isIgnored(bundleID: " com.apple.Safari")
                    && !settings.isIgnored(bundleID: "com.apple.Terminal")
            )
            settings.ignoredApps.append("  Com.Apple.Terminal ")
            check(
                "Any write is normalized, so duplicates cannot appear",
                settings.ignoredApps == [
                    "com.apple.safari",
                    "com.apple.terminal"
                ],
                detail: String(describing: settings.ignoredApps)
            )
            settings.ignoredApps.removeAll { $0 == "com.apple.terminal" }

            settings.ignorePasswordManagers = true
            check(
                "Password-manager rules are listed for the settings pane",
                settings.autoIgnoredApps.contains("com.1password.1password")
                    && settings.autoIgnoredApps
                        .contains("com.apple.keychainaccess")
                    && !settings.autoIgnoredApps
                        .contains("com.bitwarden.cli")
            )
            check(
                "Effective list merges both sources without duplicates",
                settings.effectiveIgnoredApps.filter { $0 == "com.apple.safari" }
                    .count == 1
                    && settings.effectiveIgnoredApps
                        .contains("com.1password.1password")
            )
            settings.ignorePasswordManagers = false
            check(
                "Turning the toggle off removes the automatic rules",
                settings.autoIgnoredApps.isEmpty
                    && !settings.effectiveIgnoredApps
                        .contains("com.1password.1password")
            )

            let addSuite = "ClipaIgnoreAdd-\(UUID().uuidString)"
            let addSettings = SettingsStore(
                defaults: UserDefaults(suiteName: addSuite)!

            )
            let notAnApp = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipaIgnoreAdd-\(UUID().uuidString).txt")
            try? Data("not an app".utf8).write(to: notAnApp)
            MainActor.assumeIsolated {
                check(
                    "Adding a bundle id normalizes and de-duplicates",
                    IgnoreTargetActions.add(
                        bundleID: "  COM.Example.App ",
                        to: addSettings
                    )
                        && addSettings.ignoredApps == ["com.example.app"]
                        && !IgnoreTargetActions.add(
                            bundleID: "com.example.app",
                            to: addSettings
                        )
                )
                let batch = IgnoreTargetActions.addApplications(
                    at: [notAnApp],
                    to: addSettings
                )
                check(
                    "A picked file that is not an app bundle is reported",
                    batch.added.isEmpty && batch.unusable.count == 1,
                    detail: String(describing: batch)
                )

            let storable = IgnoreTargetPresentation.make(
                resolution: .resolved(
                    bundleID: "com.apple.Safari",
                    name: "Safari"
                ),
                isAlreadyIgnored: { _ in false }
            )
            check(
                "A new app is offered by name and carries its bundle id",
                storable.title == "忽略「Safari」"
                    && storable.isEnabled
                    && storable.bundleID == "com.apple.Safari"
                    && storable.toolTip == "com.apple.Safari"
            )
            let alreadyListed = IgnoreTargetPresentation.make(
                resolution: .resolved(
                    bundleID: "com.apple.Safari",
                    name: "Safari"
                ),
                isAlreadyIgnored: { $0 == "com.apple.Safari" }
            )
            check(
                "An ignored app cannot be ignored again",
                alreadyListed.title == "已忽略「Safari」"
                    && !alreadyListed.isEnabled
                    && alreadyListed.bundleID == nil
            )
            let badBundle = IgnoreTargetPresentation.make(
                resolution: .missingBundleID(name: "plain-binary"),
                isAlreadyIgnored: { _ in false }
            )
            check(
                "A bundle-id-less app is refused up front, not on click",
                badBundle.title == "无法忽略「plain-binary」"
                    && !badBundle.isEnabled
                    && (badBundle.toolTip?.isEmpty == false)
            )
            let unknown = IgnoreTargetPresentation.make(
                resolution: .unavailable,
                isAlreadyIgnored: { _ in false }
            )
            check(
                "With no resolvable app the line stays inert and explains why",
                unknown.title == "忽略当前前台应用"
                    && !unknown.isEnabled
                    && (unknown.toolTip?.contains("先在目标应用中") ?? false),
                detail: String(describing: unknown.toolTip)
            )
            check(
                "Unknown apps fall back to their raw bundle id",
                AppIdentityCache.shared.displayName(
                    for: "com.example.missing"
                ) == "com.example.missing"
                    && AppIdentityCache.shared
                        .identity(for: "com.example.missing") == nil
            )

            let removed = IgnoreListNotice.removal(
                name: "百度网盘",
                stillAutoIgnored: false
            )
            check(
                "Removal replaces the status line",
                removed.text == "已移除 百度网盘"
                    && !removed.isWarning
                    && removed != IgnoreListNotice.removal(
                        name: "百度网盘",
                        stillAutoIgnored: true
                    )
            )
            check(
                "Removal that stays auto-ignored says so",
                IgnoreListNotice.removal(
                    name: "1Password",
                    stillAutoIgnored: true
                ).text.contains("仍由")
                    && IgnoreListNotice.removal(
                        name: "1Password",
                        stillAutoIgnored: true
                    ).isWarning
            )
        }
            try? FileManager.default.removeItem(at: notAnApp)
        }

        do {
            var gate = PasteboardCaptureGate()
            let oldEpoch = gate.epoch
            check(
                "Capture gate accepts current generation",
                gate.isCurrent(oldEpoch)
            )
            gate.beginClear(at: 100)
            check(
                "Capture gate rejects pre-clear generation",
                !gate.isCurrent(oldEpoch)
            )
            check(
                "Capture gate rejects pasteboard changes from before clear",
                !gate.shouldCapture(changeCount: 99)
                    && !gate.shouldCapture(changeCount: 100)
                    && gate.shouldCapture(changeCount: 101)
            )
        }

        do {
            check(
                "Private cover copy states encryption and where the key lives",
                PrivateCoverDisclosure.note.contains("密文")
                    && PrivateCoverDisclosure.note.contains("钥匙串")
                    && PrivateCoverDisclosure.note.contains("备份")
            )
            check(
                "Private cover copy keeps the search boundary it promises",
                PrivateCoverDisclosure.note.contains("不参与搜索")
                    && PrivateCoverDisclosure.note.contains("含图片")
            )
            check(
                "Private toast states encryption",
                PrivateCoverDisclosure.toast.contains("加密")
            )
        }

        do {
            check(
                "The only global hotkey is ⌃⌘V (never a bare Control-V)",
                HotkeySpec.panelToggle.keyCode == kVK_ANSI_V
                    && HotkeySpec.panelToggle.modifiers == cmdKey | controlKey
                    && HotkeySpec.panelToggle.modifiers != controlKey
                    && HotkeySpec.panelToggle.modifiers != cmdKey | shiftKey,
                detail: HotkeySpec.panelToggle.name
            )

            let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let strip = QuickStripController.panelFrame(in: screen)
            check(
                "Panel is horizontally centered at Spotlight-like geometry",
                abs(strip.midX - screen.midX) < 0.5
                    && abs(strip.midY - screen.height * 0.54) < 0.5
                    && strip.width >= 480
                    && strip.width <= 640
                    && strip.minY >= screen.minY
                    && strip.maxY <= screen.maxY,
                detail: "frame=\(strip)"
            )
            check(
                "A small screen keeps the panel fully on screen",
                QuickStripController.panelFrame(
                    in: NSRect(x: 0, y: 0, width: 800, height: 500)
                ).maxY <= 500
                    && QuickStripController.panelFrame(
                        in: NSRect(x: 0, y: 0, width: 800, height: 500)
                    ).minY >= 0,
                detail: "small=\(QuickStripController.panelFrame(in: NSRect(x: 0, y: 0, width: 800, height: 500)))"
            )

            let slideStart = QuickStripController.startFrame(for: strip)
            check(
                "Panel slides up from 48pt below its resting spot",
                abs(slideStart.minY - (strip.minY - 48)) < 0.5
                    && abs(slideStart.height - strip.height) < 0.5
                    && abs(slideStart.minX - strip.minX) < 0.5,
                detail: "start=\(slideStart) rest=\(strip)"
            )
            check(
                "Panel is tall enough for the list rows",
                QuickStripController.preferredHeight >= 560
                    && QuickStripView.visibleCards >= 5
                    && QuickStripView.cardPageSize >= 100,
                detail: "height=\(QuickStripController.preferredHeight)"
            )

            let paneWidth = QuickStripController.panelFrame(in: screen).width
            check(
                "List rows fit the popup without overflowing",
                QuickStripView.rowHeight == ClipaTheme.Metrics.rowHeight
                    && QuickStripView.listTopInset
                        == QuickStripView.headerBarHeight + 1
                    && QuickStripView.listTopInset + QuickStripView.rowHeight
                        <= paneWidth + 0.5
                    && QuickStripView.rowCenterY(index: 2, in: paneWidth)
                        > QuickStripView.rowCenterY(index: 1, in: paneWidth),
                detail: "row=\(QuickStripView.rowHeight) pane=\(paneWidth)"
            )

            SpotlightRowView.buildAppIndexForTesting()
            check(
                "Source app icon resolves localized names",
                SpotlightRowView.appIcon(forAppName: "终端") != nil
                    && SpotlightRowView.appIcon(forAppName: "备忘录") != nil
                    && SpotlightRowView.appIcon(forAppName: "Safari") != nil,
                detail: "终端/备忘录/Safari 图标均解析成功"
            )

            check(
                "Source app icon resolves via bundle ID",
                SpotlightRowView.appIcon(bundleID: "com.apple.finder") != nil
                    && SpotlightRowView.appIcon(bundleID: "com.apple.Notes")
                        != nil,
                detail: "Finder/Notes 按 bundleID 解析成功"
            )

            let small = NSRect(x: 0, y: 0, width: 600, height: 400)
            let smallStrip = QuickStripController.panelFrame(in: small)
            check(
                "Quick strip never exceeds a small screen",
                smallStrip.width <= small.width
                    && smallStrip.height <= small.height
                    && smallStrip.minX >= small.minX
                    && smallStrip.maxX <= small.maxX
                    && smallStrip.minY >= small.minY
                    && smallStrip.maxY <= small.maxY,
                detail: "frame=\(smallStrip)"
            )

            check(
                "Strip arrow navigation clamps at both ends",
                QuickStripController.nextIndex(
                    selectedIndex: 0, count: 5, delta: -1
                ) == 0
                    && QuickStripController.nextIndex(
                        selectedIndex: 4, count: 5, delta: 1
                    ) == 4
                    && QuickStripController.nextIndex(
                        selectedIndex: 2, count: 5, delta: 1
                    ) == 3,
                detail: "0-1→0 / 4+1→4 / 2+1→3"
            )
            check(
                "Strip arrow navigation enters the window from the near end",
                QuickStripController.nextIndex(
                    selectedIndex: nil, count: 5, delta: 1
                ) == 0
                    && QuickStripController.nextIndex(
                        selectedIndex: nil, count: 5, delta: -1
                    ) == 4
            )
            check(
                "Strip arrow navigation is a no-op on an empty strip",
                QuickStripController.nextIndex(
                    selectedIndex: nil, count: 0, delta: 1
                ) == nil
            )
        }

        do {
            MainActor.assumeIsolated {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ClipaFilterRefresh-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try? FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
                let settings = SettingsStore(
                    defaults: UserDefaults(
                        suiteName: "ClipaFilterRefresh-\(UUID().uuidString)"
                    )!

                )
                let store = ClipStore(
                    baseDirectory: dir,
                    settingsStore: settings
                )
                for index in 1...3 {
                    let text = "chip-text-\(index)"
                    _ = store.insert(
                        NewClip(
                            kind: .text,
                            text: text,
                            sourceApp: "Probe",
                            contentHash: ContentHasher.hash(text: text)
                        )
                    )
                }
                let fileURL = dir.appendingPathComponent("chip-file.txt")
                try? "chip".write(
                    to: fileURL,
                    atomically: true,
                    encoding: .utf8
                )
                _ = store.insert(
                    NewClip(
                        kind: .file,
                        text: fileURL.lastPathComponent,
                        fileURLs: [fileURL],
                        sourceApp: "Probe"
                    )
                )
                let vm = PanelViewModel(
                    store: store,
                    settings: settings
                )
                var deadline = Date().addingTimeInterval(3)
                while vm.navigationOrder.isEmpty, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Filter fixture holds three text clips and one file",
                    vm.navigationOrder.count == 4,
                    detail: "\(vm.navigationOrder.count) 条"
                )

                vm.selectKindFilter(.file)
                vm.filtersDidChange()
                deadline = Date().addingTimeInterval(3)
                while vm.navigationOrder.count > 1, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Selecting the 文件 filter re-runs the search",
                    vm.navigationOrder.count == 1
                        && vm.store.clip(id: vm.navigationOrder[0])?.kind
                            == .file,
                    detail: "\(vm.navigationOrder.count) 条"
                )

                vm.selectKindFilter(nil)
                vm.filtersDidChange()
                deadline = Date().addingTimeInterval(3)
                while vm.navigationOrder.count < 4, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Clearing the filter brings the whole history back",
                    vm.navigationOrder.count == 4,
                    detail: "\(vm.navigationOrder.count) 条"
                )
            }
        }

        do {
            let width = 2000
            let height = 1200
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            let png: Data? = {
                guard let context,
                      let image = context.makeImage() else { return nil }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    data,
                    "public.png" as CFString,
                    1,
                    nil
                ) else { return nil }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { return nil }
                return data as Data
            }()
            check(
                "Image decode fixture encodes a \(width)×\(height) PNG",
                png != nil
            )

            let target = StripThumbnailView.previewMaxPixel(
                boxSize: CGSize(width: 250, height: 150),
                displayScale: 2
            )
            check(
                "Decode target follows the displayed box (250×150pt @2x → 500)",
                target == 500,
                detail: "target=\(target)"
            )
            check(
                "Decode target never drops below the softness floor",
                StripThumbnailView.previewMaxPixel(
                    boxSize: CGSize(width: 100, height: 60),
                    displayScale: 1
                ) == StripThumbnailView.minPixel
                    && StripThumbnailView.minPixel >= 480,
                detail: "minPixel=\(StripThumbnailView.minPixel)"
            )
            check(
                "Decode target never exceeds the memory ceiling",
                StripThumbnailView.previewMaxPixel(
                    boxSize: CGSize(width: 900, height: 700),
                    displayScale: 3
                ) == StripThumbnailView.maxPixel
                    && StripThumbnailView.maxPixel == 1024,
                detail: "maxPixel=\(StripThumbnailView.maxPixel)"
            )
            let decoded = png.flatMap {
                StripThumbnailView.decodePreview($0, maxPixel: target)
            }
            let longest = decoded.map {
                max($0.size.width, $0.size.height)
            } ?? 0
            check(
                "Card image is decoded at display size, not thumbnail size",
                abs(longest - CGFloat(target)) <= 1,
                detail: "long edge=\(Int(longest))px target=\(target)"
            )
            check(
                "Card image decode keeps the source aspect ratio",
                abs(
                    (decoded?.size.width ?? 0) / max(decoded?.size.height ?? 1, 1)
                        - CGFloat(width) / CGFloat(height)
                ) < 0.02,
                detail: "\(Int(decoded?.size.width ?? 0))×"
                    + "\(Int(decoded?.size.height ?? 0))"
            )
        }

        do {
            MainActor.assumeIsolated {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ClipaCardPaging-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try? FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
                let settings = SettingsStore(
                    defaults: UserDefaults(
                        suiteName: "ClipaCardPaging-\(UUID().uuidString)"
                    )!

                )

                settings.historyLimit = 0
                let store = ClipStore(
                    baseDirectory: dir,
                    settingsStore: settings
                )

                let rowCount = PanelViewModel.listWindowPageSize + 250
                for index in 0..<rowCount {
                    let text = "paging-\(index)"
                    _ = store.insert(
                        NewClip(
                            kind: .text,
                            text: text,
                            sourceApp: "Probe",
                            contentHash: ContentHasher.hash(text: text)
                        )
                    )
                }
                let vm = PanelViewModel(store: store, settings: settings)
                var deadline = Date().addingTimeInterval(10)
                while vm.navigationOrder.count < rowCount, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Paging fixture holds \(rowCount) rows",
                    vm.navigationOrder.count == rowCount,
                    detail: "\(vm.navigationOrder.count)"
                )
                let firstPage = vm.renderedClips.count
                check(
                    "Card row starts with one page, not the whole library",
                    firstPage >= PanelViewModel.listWindowPageSize - 1
                        && firstPage < rowCount
                        && vm.canLoadMoreCards,
                    detail: "first=\(firstPage)"
                )

                vm.extendRenderedWindow()
                let secondPage = vm.renderedClips.count
                check(
                    "Scrolling to the end loads the next page of cards",
                    secondPage > firstPage,
                    detail: "\(firstPage) → \(secondPage)"
                )

                var guardCount = 0
                while vm.canLoadMoreCards, guardCount < 20 {
                    vm.extendRenderedWindow()
                    guardCount += 1
                }
                check(
                    "Paging reaches the end of the result set",
                    vm.renderedClips.count == rowCount
                        && !vm.canLoadMoreCards,
                    detail: "\(vm.renderedClips.count)/\(rowCount)"
                        + " pages=\(guardCount + 2)"
                )
                try? FileManager.default.removeItem(at: dir)
            }
        }

        do {
            MainActor.assumeIsolated {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ClipaImageBurst-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try? FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
                let settings = SettingsStore(
                    defaults: UserDefaults(
                        suiteName: "ClipaImageBurst-\(UUID().uuidString)"
                    )!

                )
                let store = ClipStore(
                    baseDirectory: dir,
                    settingsStore: settings
                )
                let png = Self.makeProbePNG(width: 64, height: 40)
                let clipCount = 10
                if let png {
                    for index in 0..<clipCount {
                        _ = store.insert(
                            NewClip(
                                kind: .image,
                                text: "",
                                imageData: png,
                                imageFormat: "public.png",
                                sourceApp: "Probe",
                                contentHash: ContentHasher.hash(
                                    data: png + Data([UInt8(index)])
                                )
                            )
                        )
                    }
                }
                let imageClips = store.items.filter { $0.kind == .image }
                check(
                    "Image burst fixture holds \(clipCount) image clips",
                    imageClips.count == clipCount,
                    detail: "\(imageClips.count)"
                )
                guard imageClips.count == clipCount else { return }

                let vm = PanelViewModel(store: store, settings: settings)
                let expected = imageClips.count + 1
                let finished = DispatchSemaphore(value: 0)

                for clip in imageClips {
                    Task.detached(priority: .userInitiated) {
                        _ = await store.imageDataAsync(for: clip)
                        finished.signal()
                    }
                }

                Task { @MainActor in
                    await vm.copyAsync(imageClips[0])
                    finished.signal()
                }

                var received = 0
                let deadline = Date().addingTimeInterval(20)
                while received < expected, Date() < deadline {
                    if finished.wait(timeout: .now() + 0.2) == .success {
                        received += 1
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                check(
                    "Concurrent image reads plus a copy finish (no pool deadlock)",
                    received == expected,
                    detail: "\(received)/\(expected) finished"
                )

                check(
                    "Store still answers after the image burst",
                    store.imageData(for: imageClips[0]) == png
                )
                try? FileManager.default.removeItem(at: dir)
            }
        }

        do {
            MainActor.assumeIsolated {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ClipaPopupModules-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try? FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
                let settings = SettingsStore(
                    defaults: UserDefaults(
                        suiteName: "ClipaPopupModules-\(UUID().uuidString)"
                    )!

                )
                let store = ClipStore(
                    baseDirectory: dir,
                    settingsStore: settings
                )
                let jsonText = """
                {"name":"nginx","replicas":3,"env":"production"}
                """
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: jsonText,
                        note: "本周部署的 nginx 配置",
                        sourceApp: "VS Code",
                        contentHash: ContentHasher.hash(text: "popup-json")
                    )
                )
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: "https://kubernetes.io/zh-cn/docs/",
                        sourceApp: "Safari",
                        contentHash: ContentHasher.hash(text: "popup-url")
                    )
                )
                let vm = PanelViewModel(
                    store: store,
                    settings: settings
                )
                var deadline = Date().addingTimeInterval(3)
                while vm.navigationOrder.count < 2, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Popup fixture rows arrived",
                    vm.navigationOrder.count == 2,
                    detail: "\(vm.navigationOrder.count) 条"
                )
                guard let json = store.items.first(where: {
                    $0.smartTag == .json
                }), let url = store.items.first(where: {
                    $0.text.hasPrefix("https://")
                }) else {
                    check("Popup fixture clips are classified", false)
                    return
                }
                check(
                    "Popup fixture clips are classified",
                    json.smartTag == .json,
                    detail: json.smartTag.rawValue
                )

                vm.selectKindFilter(nil)
                vm.selectSmartTagFilter(.json)
                vm.filtersDidChange()
                deadline = Date().addingTimeInterval(3)
                while vm.navigationOrder.count > 1, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Popup filter menu filters to JSON",
                    vm.navigationOrder.count == 1
                        && vm.store.clip(id: vm.navigationOrder[0])?.id
                            == json.id,
                    detail: "\(vm.navigationOrder.count) 条"
                )
                vm.selectSmartTagFilter(nil)
                vm.filtersDidChange()
                deadline = Date().addingTimeInterval(3)
                while vm.navigationOrder.count < 2, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Popup filter menu returns to 全部",
                    vm.navigationOrder.count == 2,
                    detail: "\(vm.navigationOrder.count) 条"
                )

                var done = false
                vm.openNoteEditor(json)
                check(
                    "Note editor opens with the clip's current note",
                    vm.showNoteEditor && vm.noteDraft == json.note
                )
                vm.noteDraft = "改过的备注"
                done = false
                Task { @MainActor in
                    await vm.saveNoteAsync()
                    done = true
                }
                deadline = Date().addingTimeInterval(3)
                while !done, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Note saved from the popup editor is persisted",
                    store.clip(id: json.id)?.note == "改过的备注"
                        && !vm.showNoteEditor
                )

                done = false
                Task { @MainActor in
                    await vm.togglePrivateAsync(url)
                    done = true
                }
                deadline = Date().addingTimeInterval(3)
                while !done, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    "Popup private cover locks the clip",
                    store.clip(id: url.id)?.isPrivate == true
                        && (store.clip(id: url.id).map {
                            vm.isPrivateUnlocked($0)
                        } ?? true) == false
                )

                let page = Self.makeProbeImage(
                    view: QuickStripView(vm: vm),
                    size: NSSize(width: 900, height: 306)
                )
                if let page {
                    var samples: [Double] = []
                    for y in stride(from: 0, to: page.pixelsHigh, by: 6) {
                        for x in stride(from: 0, to: page.pixelsWide, by: 6) {
                            guard let color = page.colorAt(x: x, y: y) else {
                                continue
                            }
                            samples.append(
                                0.2126 * color.redComponent
                                    + 0.7152 * color.greenComponent
                                    + 0.0722 * color.blueComponent
                            )
                        }
                    }
                    let mean = samples.isEmpty
                        ? 0
                        : samples.reduce(0, +) / Double(samples.count)
                    let contrasting = samples.reduce(0) {
                        $0 + (abs($1 - mean) > 0.25 ? 1 : 0)
                    }
                    check(
                        "Popup page renders text and chrome, not a blank pane",
                        !samples.isEmpty
                            && Double(contrasting) / Double(samples.count)
                                > 0.01,
                        detail: "ink=\(contrasting)/\(samples.count)"
                    )
                }
            }
        }

        do {
            let suite = "ClipaSecureEraseSettingTest-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = SettingsStore(
                defaults: defaults

            )
            check(
                "Secure erase setting defaults off",
                !settings.secureEraseHistoryOnClear
            )
            settings.secureEraseHistoryOnClear = true
            let reloaded = SettingsStore(
                defaults: defaults

            )
            check(
                "Secure erase setting persists",
                reloaded.secureEraseHistoryOnClear
            )
            defaults.removePersistentDomain(forName: suite)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaSecureClearTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            store.settings.secureEraseHistoryOnClear = true
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: "secure-clear-pinned",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "secure-clear-pinned")
                )
            )

            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: "secure-clear-removed",
                    sourceApp: "Probe",
                    isPrivate: true,
                    contentHash: ContentHasher.hash(
                        text: "secure-clear-removed"
                    )
                )
            )
            store.clearAll()
            check("Secure clear empties the history", store.items.isEmpty)
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaClearCoverageTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: "clear-fts-removed",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "clear-fts-removed")
                )
            )
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: "clear-fts-pinned",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "clear-fts-pinned")
                )
            )

            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: "clear-private-removed",
                    sourceApp: "Probe",
                    isPrivate: true,
                    contentHash: ContentHasher.hash(
                        text: "clear-private-removed"
                    )
                )
            )

            let removedImageData = Data([1, 2, 3])
            let keptImageData = Data([4, 5, 6])
            _ = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: removedImageData,
                    imageFormat: "public.png",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(data: removedImageData)
                )
            )
            _ = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: keptImageData,
                    imageFormat: "public.png",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(data: keptImageData)
                )
            )
            let summary = store.clearSummary
            check(
                "Clear summary counts every removable row and the private ones",
                summary == ClipClearSummary(
                    removable: 5,
                    privateCount: 1
                ) && summary.requiresAuthentication
            )

            store.clearAll()
            check("Clear removes every row", store.items.isEmpty)

            if let database = store.database {
                let state: (fts: Int, clips: [Clip])? = try? DatabaseSync.run(
                    database
                ) { db in
                    (
                        try await db.ftsCount(),
                        try await db.loadRecentClips()
                    )
                }
                check(
                    "Clear keeps FTS and clips aligned",
                    state?.fts == 0
                        && state?.clips.isEmpty == true
                )

                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: "clear-rollback-a",
                        sourceApp: "Probe",
                        contentHash: ContentHasher.hash(
                            text: "clear-rollback-a"
                        )
                    )
                )
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: "clear-rollback-b",
                        sourceApp: "Probe",
                        contentHash: ContentHasher.hash(
                            text: "clear-rollback-b"
                        )
                    )
                )
                var forcedFailure = false
                do {
                    _ = try DatabaseSync.run(database) { db in
                        try await db.clearAll(
                            secureErase: false,
                            failAfterDeleteForTesting: true
                        )
                    }
                } catch {
                    forcedFailure = true
                }
                store.reloadFromDatabase()
                let rolledBack: (fts: Int, clips: [Clip])? =
                    try? DatabaseSync.run(database) { db in
                        (
                            try await db.ftsCount(),
                            try await db.loadRecentClips()
                        )
                    }
                check(
                    "Clear rollback preserves rows and FTS",
                    forcedFailure
                        && store.items.count == 2
                        && rolledBack?.fts == 2
                        && rolledBack?.clips.count == 2
                        && rolledBack?.clips.contains {
                            $0.text == "clear-rollback-a"
                        } == true
                )
            } else {
                check("Clear coverage database fixture", false)
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipSecureDeleteModeTest-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: "secure-mode-probe",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "secure-mode-probe")
                )
            )
            if let database = store.database {
                let before: Int? = try? DatabaseSync.run(database) { db in
                    try await db.secureDeleteMode()
                }
                store.clearAll()
                let afterPlainClear: Int? = try? DatabaseSync.run(database) { db in
                    try await db.secureDeleteMode()
                }
                check(
                    "Plain clear keeps the default secure_delete mode",
                    before != nil && afterPlainClear == before
                )

                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: "secure-mode-probe-2",
                        sourceApp: "Probe",
                        contentHash: ContentHasher.hash(
                            text: "secure-mode-probe-2"
                        )
                    )
                )
                store.settings.secureEraseHistoryOnClear = true
                store.clearAll()
                let afterSecureClear: Int? = try? DatabaseSync.run(database) { db in
                    try await db.secureDeleteMode()
                }
                check(
                    "Secure clear raises secure_delete to ON",
                    afterSecureClear == 1
                )
            } else {
                check("Plain clear keeps the default secure_delete mode", false)
                check("Secure clear raises secure_delete to ON", false)
            }
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let yamlType = ClipTypePresentation.resolve(
                kind: .text,
                smartTag: .yaml
            )
            check(
                "Type presentation shows the refined format",
                yamlType.title == "YAML"
                    && yamlType.tintHex == SmartTag.yaml.tintHex
                    && yamlType.source == .smartTag(.yaml)
            )
            let plainText = ClipTypePresentation.resolve(
                kind: .text,
                smartTag: .text
            )
            check(
                "Type presentation keeps plain text unrefined",
                plainText.title == "文本"
                    && plainText.source == .kind(.text)
            )
            let yamlClip = Clip(
                dbID: 1,
                id: UUID(),
                kind: .text,
                text: "apiVersion: v1\nkind: ConfigMap",
                createdAt: Date(),
                lastCopiedAt: Date(),
                updatedAt: Date(),
                smartTag: .yaml
            )
            check(
                "Clip type presentation prefers its smart tag",
                yamlClip.typePresentation.title == "YAML"
            )
            check(
                "Plan type chips drop kinds refined by a smart tag",
                ClipTypePresentation.titles(
                    kinds: [.text],
                    smartTags: [.markdown]
                ) == ["Markdown"]
                    && ClipTypePresentation.titles(
                        kinds: [.text],
                        smartTags: [.yaml]
                    ) == ["YAML"]
                    && ClipTypePresentation.titles(
                        kinds: [.image, .file],
                        smartTags: []
                    ) == ["图片", "文件"]
            )
        }

        do {
            check(
                "Type set is text/JSON/YAML/Markdown/image/file",
                SmartTag.allCases == [
                    .text, .json, .yaml, .markdown, .image, .file
                ]
                    && ClipKind.allCases == [.text, .image, .file]
            )
            check(
                "Retired kinds decode as text",
                ClipKind(databaseValue: 1) == .text
                    && ClipKind(databaseValue: 2) == .text
            )
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaSearchParity-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            let corpus = SearchParity.adversarialCorpus()
            let inserted = store.replaceAllForTesting(corpus)
            check(
                "Parity corpus is inserted",
                inserted.count == corpus.count,
                detail: "\(inserted.count)/\(corpus.count)"
            )

            let status = store.database.flatMap { database in
                awaitAsync { try await database.searchNormalizationStatus() }
            }
            check(
                "Normalized text columns are backfilled for every row",
                status?.ready == true
                    && status?.pending == 0
                    && status?.clips == inserted.count,
                detail: String(describing: status)
            )

            let comparisons = SearchParity.compare(
                store: store,
                queries: SearchParity.adversarialQueries()
            )
            let mismatches = comparisons.filter { !$0.isMatch }
            check(
                "SQL fast path returns the same clips in the same order as the oracle",
                comparisons.count > 0 && mismatches.isEmpty,
                detail: mismatches.prefix(3).map {
                    "\($0.query)/\($0.planShape) oracle=\($0.oracle)"
                        + " fast=\($0.fast)"
                }.joined(separator: " | ")
            )
            check(
                "Fast path actually engaged, so the comparison is not vacuous",
                comparisons.contains(where: \.fastPathEngaged),
                detail: "engaged=\(comparisons.filter(\.fastPathEngaged).count)"
            )

            let kindFiltered = SearchParity.compare(
                store: store,
                queries: ["网络", "docker", "report"],
                filter: SearchFilter(kinds: [.text])
            )
            check(
                "Fast path parity holds with a metadata filter",
                kindFiltered.allSatisfy(\.isMatch)
            )

            let scoringMismatches = SearchParity.scoringMismatches(
                store: store,
                queries: SearchParity.adversarialQueries()
            )
            check(
                "Evidence-based ranking reproduces the reference order",
                scoringMismatches.isEmpty,
                detail: scoringMismatches.prefix(2).map {
                    "\($0.query)/\($0.planShape) reference=\($0.oracle)"
                        + " evidence=\($0.fast)"
                }.joined(separator: " | ")
            )

            let emojiEngine = LocalSearchEngine(
                database: store.database,
                store: store
            )
            let partialEmojiPlan = SearchParity.plans(for: "👨").first?.plan
            let partialEmoji = partialEmojiPlan.map {
                emojiEngine.search(
                    query: "👨",
                    filter: SearchFilter(),
                    store: store,
                    plan: $0
                )
            }
            check(
                "Partial emoji cluster never matches a ZWJ family clip",
                partialEmoji?.clips.isEmpty == true,
                detail: partialEmoji.map {
                    $0.clips.map(\.text).joined(separator: " | ")
                } ?? "no plan"
            )

            let ambiguousPlan = SearchParity.plans(for: "👨‍👩‍👧").first?.plan
            let ambiguousResponse = ambiguousPlan.map {
                LocalSearchEngine(
                    database: store.database,
                    store: store,
                    textMatchMode: .sqlOnly
                ).search(
                    query: "👨‍👩‍👧",
                    filter: SearchFilter(),
                    store: store,
                    plan: $0
                )
            }
            check(
                "Ambiguous term falls back to the oracle instead of SQL",
                ambiguousResponse?.metrics?.exactFastPath == false
                    && ambiguousResponse?.clips.count == 1,
                detail: "fastPath=\(String(describing: ambiguousResponse?.metrics?.exactFastPath))"
                    + " hits=\(ambiguousResponse?.clips.count ?? -1)"
            )

            let noteClip = inserted.first
            var noteParityFailed = false
            if let noteClip, store.setNote("freshly-edited-note", for: noteClip) {
                let probes = SearchParity.compare(
                    store: store,
                    queries: ["freshly-edited-note"]
                )
                noteParityFailed = probes.contains { !$0.isMatch }
                    || probes.allSatisfy { $0.fast == [] }
            } else {
                noteParityFailed = true
            }
            check(
                "Note edits keep the normalized fast path in sync",
                !noteParityFailed
            )

            let rowProbes = SearchParity.compare(
                store: store,
                queries: SearchParity.probes(from: store)
            )
            check(
                "Row-derived probes agree between oracle and fast path",
                rowProbes.allSatisfy(\.isMatch)
            )

            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaConcurrentSearch-\(UUID().uuidString)",
                    isDirectory: true
                )
            let store = makeStore(dir)
            for index in 0..<6 {
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: "concurrent-search-row-\(index)",
                        note: "note-\(index)",
                        contentHash: ContentHasher.hash(
                            text: "concurrent-\(index)"
                        )
                    )
                )
            }
            let pipeline = DefaultSearchPipeline(
                store: store,
                localSearchEngine: LocalSearchEngine(
                    database: store.database,
                    store: store
                )
            )

            let snapshot = store.searchSnapshot
            let concurrency = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let group = DispatchGroup()
            for index in 0..<concurrency {
                group.enter()
                Task.detached(priority: .userInitiated) {
                    _ = await pipeline.performLocalSearchAsync(
                        query: "concurrent-search-row-\(index % 6)",
                        uiFilter: SearchFilter(),
                        dataSource: snapshot
                    )
                    group.leave()
                }
            }
            let finished = group.wait(timeout: .now() + 20) == .success
            check(
                "并发异步检索不会因阻塞协作线程而卡死",
                finished,
                detail: "concurrency=\(concurrency)"
            )
            try? FileManager.default.removeItem(at: dir)
        }

        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaFTSIndex-\(UUID().uuidString)",
                    isDirectory: true
                )
            func openMarker() -> FTSRepository.IndexMarker? {
                guard let manager = try? DatabaseManager(baseDirectory: dir)
                else { return nil }
                return (try? DatabaseSync.run(manager) { db in
                    try await db.ftsIndexMarker()
                }) ?? nil
            }
            func exec(_ sql: String) -> Bool {
                guard let connection = try? DatabaseConnection(
                    path: DatabaseManager.databaseURL(in: dir).path
                ) else { return false }
                do {
                    try connection.exec(sql)
                    return true
                } catch {
                    return false
                }
            }

            let drafts = [
                NewClip(
                    kind: .text,
                    text: "index-check-alpha",
                    note: "note-alpha",
                    contentHash: ContentHasher.hash(text: "index-a")
                ),
                NewClip(
                    kind: .text,
                    text: "index-check-beta",
                    note: "note-beta",
                    contentHash: ContentHasher.hash(text: "index-b")
                ),
                NewClip(
                    kind: .text,
                    text: "index-check-gamma",
                    note: "note-gamma",
                    contentHash: ContentHasher.hash(text: "index-c")
                )
            ]

            var inserted = 0
            if let manager = try? DatabaseManager(baseDirectory: dir) {
                inserted = (try? DatabaseSync.run(manager) { db in
                    try await db.replaceAllForTesting(drafts).count
                }) ?? 0
                _ = try? DatabaseSync.run(manager) { db in
                    try await db.rebuildFTS()
                }
            }
            check(
                "FTS 索引：首次开库建立标记并覆盖全部行",
                inserted == drafts.count
                    && openMarker()?.buildCount == 2
                    && openMarker()?.rowCount == drafts.count,
                detail: "inserted=\(inserted) marker=\(String(describing: openMarker()))"
            )

            let skipped = openMarker()
            check(
                "FTS 索引：校验通过时跳过重建",
                skipped?.buildCount == 2,
                detail: "buildCount=\(String(describing: skipped?.buildCount))"
            )

            let deleted = exec("DELETE FROM clips_fts WHERE rowid = 1")
            let afterDelete = openMarker()
            check(
                "FTS 索引：行集漂移被检出并重建",
                deleted && afterDelete?.buildCount == 3,
                detail: "buildCount=\(String(describing: afterDelete?.buildCount))"
            )

            let rewritten = exec("""
                UPDATE clips_fts SET text = 'index-check-betx' WHERE rowid = 2
                """)
            let afterRewrite = openMarker()
            check(
                "FTS 索引：等长内容改写被抽样校验收出",
                rewritten && afterRewrite?.buildCount == 4,
                detail: "buildCount=\(String(describing: afterRewrite?.buildCount))"
            )

            let tampered = exec("""
                UPDATE clips_fts SET note = 'note-tampered' WHERE rowid = 3
                """)
            var strongDetail = ""
            var strongOK = true
            if let connection = try? DatabaseConnection(
                path: DatabaseManager.databaseURL(in: dir).path
            ) {
                let result = try? FTSRepository.verifyStrong(
                    connection: connection
                )
                strongOK = result?.ok ?? true
                strongDetail = result?.detail ?? ""
            }
            check(
                "强校验能定位到具体行",
                tampered && !strongOK && strongDetail.contains("3"),
                detail: strongDetail
            )

            let probeEdited = exec("""
                UPDATE store_meta SET value = replace(value, '"abc"', '"XYZ"')
                WHERE key = 'fts.index_marker'
                """)
            let afterProbe = openMarker()
            check(
                "FTS 索引：归一化器指纹变化触发重建",
                probeEdited && afterProbe?.buildCount == 5,
                detail: "buildCount=\(String(describing: afterProbe?.buildCount))"
            )

            try? FileManager.default.removeItem(at: dir)
        }

        let total = passed + failures
        print(failures == 0
              ? "========== 全部通过（\(passed)/\(total)） =========="
              : "========== 存在 \(failures) 项失败（通过 \(passed)/\(total)） ==========")
        return Int32(failures)
    }

    @MainActor
    static func cryptoProbe() -> Int32 {
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition {
                print("[CRYPTO] FAIL \(label)")
                failures += 1
            }
        }

        let key = (try? StoreCrypto.generateKey()) ?? Data()
        expect(
            key.count == StoreCrypto.keyByteCount,
            "随机密钥 \(StoreCrypto.keyByteCount) 字节"
        )
        let sealed = (try? StoreCrypto.seal("13812345678", key: key)) ?? ""
        expect(StoreCrypto.isEnvelope(sealed), "密文带自识别前缀")
        expect(!sealed.contains("13812345678"), "密文里不含明文")
        expect(
            (try? StoreCrypto.open(sealed, key: key)) == "13812345678",
            "同一把密钥解得开"
        )
        let sealedAgain = (try? StoreCrypto.seal("13812345678", key: key)) ?? ""
        expect(sealed != sealedAgain, "同一明文两次加密结果不同（独立 nonce）")
        expect(
            (try? StoreCrypto.open(sealedAgain, key: key)) == "13812345678",
            "第二条同样解得开"
        )

        var tampered = Array(sealed.utf8)
        if tampered.count > 24 {
            tampered[24] = tampered[24] == 65 ? 66 : 65
        }
        expect(
            (try? StoreCrypto.open(
                String(decoding: tampered, as: UTF8.self),
                key: key
            )) == nil,
            "被改动的密文解不开"
        )
        expect(
            (try? StoreCrypto.open(
                sealed,
                key: (try? StoreCrypto.generateKey()) ?? Data()
            )) == nil,
            "换一把密钥解不开"
        )
        expect(
            StoreCrypto.openStored("普通文本") == "普通文本",
            "非密文原样返回（没加密的历史行仍可读）"
        )
        expect(StoreCrypto.openStored("") == "", "空串原样返回")

        let probePlain = "钥匙串留存探测 \(UUID().uuidString)"
        let probeSealed = (try? StoreCrypto.sealForStorage(probePlain)) ?? ""
        expect(
            StoreCrypto.isEnvelope(probeSealed),
            "用钥匙串密钥加密成功（首次运行时在这一步生成）"
        )

        let keyStatus = StoreCrypto.keyStatus()
        expect(
            keyStatus.present && keyStatus.error == nil,
            "钥匙串里有数据密钥（\(keyStatus.error ?? "ok")）"
        )

        StoreCrypto.forgetCachedKey()
        expect(
            StoreCrypto.openStored(probeSealed) == probePlain,
            "丢掉缓存后仍解得开（密钥确实在钥匙串，而不是在内存里）"
        )

        let root = ClipStore.defaultBaseDirectory()
        let settings = SettingsStore(
            defaults: UserDefaults(
                suiteName: "ClipaCryptoProbe-\(UUID().uuidString)"
            )!
        )
        let store = ClipStore(baseDirectory: root, settingsStore: settings)
        guard store.database != nil else {
            print("[CRYPTO] 打不开临时库")
            return 1
        }
        let dbURL = root.appendingPathComponent("clips.sqlite")
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")

        func fileContains(_ needle: String, at url: URL) -> Bool {
            guard let data = try? Data(contentsOf: url) else { return false }
            return data.range(of: Data(needle.utf8)) != nil
        }

        func storedPlaintextLeaked(_ needle: String) -> Bool {
            fileContains(needle, at: dbURL) || fileContains(needle, at: walURL)
        }

        let privateMarker = "M3-PRIVATE-\(UUID().uuidString)"
        let controlMarker = "M3-CONTROL-\(UUID().uuidString)"
        let privateBody = "私密正文 \(privateMarker)"
        let privateNote = "私密备注 \(privateMarker)"
        _ = store.insert(
            NewClip(
                kind: .text,
                text: privateBody,
                note: privateNote,
                sourceApp: "Notes",
                isPrivate: true
            )
        )
        _ = store.insert(
            NewClip(
                kind: .text,
                text: "普通正文 \(controlMarker)",
                sourceApp: "Terminal"
            )
        )

        guard let privateClip = store.items.first(where: {
                  $0.text.contains(privateMarker)
              }),
              let controlClip = store.items.first(where: {
                  $0.text.contains(controlMarker)
              })
        else {
            print("[CRYPTO] 夹具没建成")
            return 1
        }
        expect(privateClip.isPrivate, "私密夹具是私密条目")
        expect(privateClip.text == privateBody, "私密条目读出来是原文（解密路径通）")
        expect(privateClip.note == privateNote, "私密备注读出来是原文")

        expect(
            storedPlaintextLeaked(controlMarker),
            "对照组：普通条目明文**在**文件或 WAL 里（证明扫描有效）"
        )
        expect(
            !fileContains(privateMarker, at: dbURL),
            "clips.sqlite 里找不到私密明文（原始字节扫描）"
        )
        expect(
            !fileContains(privateMarker, at: walURL),
            "WAL 里也找不到（改前的整页镜像已被检查点截断）"
        )

        let raw = try? DatabaseConnection(path: dbURL.path)
        func storedValue(_ sql: String, _ dbID: Int64) -> String {
            guard let raw else { return "" }
            let value: String? = try? raw.prepare(sql) { statement in
                sqlite3_bind_int64(statement, 1, dbID)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return raw.columnText(statement, 0)
            }
            return value ?? ""
        }
        let storedBody = storedValue(
            "SELECT text FROM clips WHERE db_id = ?",
            privateClip.dbID
        )
        expect(
            StoreCrypto.isEnvelope(storedBody),
            "库里私密正文是密文（直接读列）"
        )
        expect(!storedBody.contains(privateMarker), "密文里不含明文")
        expect(
            storedValue(
                "SELECT COALESCE(norm_text,'') FROM clips WHERE db_id = ?",
                privateClip.dbID
            ).isEmpty,
            "norm_text 已清空（索引用的第二份明文）"
        )
        expect(
            storedValue(
                "SELECT COALESCE(norm_note,'') FROM clips WHERE db_id = ?",
                privateClip.dbID
            ).isEmpty,
            "norm_note 已清空"
        )
        expect(
            storedValue(
                "SELECT COALESCE(text,'') FROM clips_fts WHERE rowid = ?",
                privateClip.dbID
            ).isEmpty,
            "FTS 索引里没有私密正文"
        )
        expect(
            !storedValue(
                "SELECT COALESCE(text,'') FROM clips_fts WHERE rowid = ?",
                controlClip.dbID
            ).isEmpty,
            "对照组：普通条目仍在 FTS 索引里"
        )

        expect(
            store.memoryIndex.allIDs().contains(privateClip.dbID),
            "私密条目仍在列表里（不是被隐藏）"
        )
        let fields = store.memoryIndex.normalizedFields(dbID: privateClip.dbID)
        expect(
            fields != nil && fields!.body.isEmpty && fields!.note.isEmpty,
            "内存索引里没有私密正文"
        )

        let engine = LocalSearchEngine(database: store.database, store: store)
        let privateHits = engine.search(
            query: privateMarker,
            filter: SearchFilter(),
            store: store
        ).clips.map(\.dbID)
        expect(privateHits.isEmpty, "搜索找不到私密内容")
        let controlHits = engine.search(
            query: controlMarker,
            filter: SearchFilter(),
            store: store
        ).clips.map(\.dbID)
        expect(
            controlHits.contains(controlClip.dbID),
            "对照组：同样的查询能找到普通条目（搜索本身是好的）"
        )

        expect(store.togglePrivate(dbID: privateClip.dbID), "取消私密成功")
        expect(
            store.clip(id: privateClip.id)?.text == privateBody,
            "取消私密后读到的仍是原文"
        )
        expect(
            !StoreCrypto.isEnvelope(
                storedValue("SELECT text FROM clips WHERE db_id = ?", privateClip.dbID)
            ),
            "落盘变回明文"
        )
        expect(
            !storedValue(
                "SELECT COALESCE(norm_text,'') FROM clips WHERE db_id = ?",
                privateClip.dbID
            ).isEmpty,
            "norm_text 恢复"
        )
        expect(
            engine.search(
                query: privateMarker,
                filter: SearchFilter(),
                store: store
            ).clips.map(\.dbID).contains(privateClip.dbID),
            "搜索又能找到它了（索引副本已放回）"
        )
        expect(store.togglePrivate(dbID: privateClip.dbID), "再设回私密成功")
        expect(
            StoreCrypto.isEnvelope(
                storedValue("SELECT text FROM clips WHERE db_id = ?", privateClip.dbID)
            ),
            "再设回私密后落盘又是密文"
        )

        let legacyMarker = "M3-LEGACY-\(UUID().uuidString)"
        let legacyBody = "老库私密 \(legacyMarker)"
        _ = store.insert(
            NewClip(kind: .text, text: legacyBody, sourceApp: "Notes")
        )
        guard let legacyClip = store.items.first(where: {
            $0.text.contains(legacyMarker)
        }) else {
            print("[CRYPTO] 老库夹具没建成")
            return 1
        }
        try? raw?.exec(
            "UPDATE clips SET is_private = 1 WHERE db_id = \(legacyClip.dbID)"
        )
        try? raw?.exec(
            "DELETE FROM store_meta WHERE key = 'crypto.private_content_version'"
        )
        expect(
            storedPlaintextLeaked(legacyMarker),
            "迁移前：老库形态的私密明文在库里（对照）"
        )
        let reopenedStore = ClipStore(
            baseDirectory: root,
            settingsStore: settings
        )
        guard reopenedStore.database != nil else {
            print("[CRYPTO] 迁移后打不开库")
            return 1
        }
        reopenedStore.reloadFromDatabase()
        expect(
            !storedPlaintextLeaked(legacyMarker),
            "迁移后：那段明文已从主文件与 WAL 里消失"
        )
        expect(
            reopenedStore.clip(id: legacyClip.id)?.text == legacyBody,
            "迁移后仍能读到原文（解密路径通）"
        )
        expect(
            StoreCrypto.isEnvelope(
                storedValue(
                    "SELECT text FROM clips WHERE db_id = ?",
                    legacyClip.dbID
                )
            ),
            "迁移后落盘是密文"
        )
        expect(
            reopenedStore.clip(id: privateClip.id)?.text == privateBody,
            "迁移不碰已加密的行（幂等）"
        )

        let envelopeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipa-crypto-probe-envelope.txt")
        let previous = (
            try? String(contentsOf: envelopeFile, encoding: .utf8)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let previous, !previous.isEmpty {
            expect(
                StoreCrypto.openStored(previous) == "clipa-crypto-probe",
                "上一轮写下的密文这一轮仍解得开（密钥跨重建留存）"
            )
        } else {
            print("[CRYPTO] 首次运行：已写下探测密文，下次运行会验证密钥留存")
        }
        try? (try? StoreCrypto.sealForStorage("clipa-crypto-probe"))?
            .write(to: envelopeFile, atomically: true, encoding: .utf8)

        do {
            let publicPNG = Self.makeProbePNG(width: 150, height: 100)
            let togglePNG = Self.makeProbePNG(width: 96, height: 64)
            let legacyPNG = Self.makeProbePNG(width: 80, height: 50)
            guard publicPNG != nil, togglePNG != nil, legacyPNG != nil else {
                expect(false, "私密图片 fixture 生成")
                return failures == 0 ? 0 : 1
            }
            let clipByHash = { (data: Data) -> Clip? in
                store.items.first {
                    $0.contentHash == ContentHasher.hash(data: data)
                }
            }

            _ = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: publicPNG,
                    imageFormat: "public.png",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(data: publicPNG!)
                )
            )

            _ = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: togglePNG,
                    imageFormat: "public.png",
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(data: togglePNG!)
                )
            )

            _ = store.insert(
                NewClip(
                    kind: .image,
                    text: "",
                    imageData: legacyPNG,
                    imageFormat: "public.png",
                    sourceApp: "Probe",
                    isPrivate: true,
                    contentHash: ContentHasher.hash(data: legacyPNG!)
                )
            )
            if let item = clipByHash(togglePNG!) {
                expect(
                    store.togglePrivate(dbID: item.dbID),
                    "togglePrivate 走面板同一路径成功"
                )
                let hex = storedValue(
                    "SELECT hex(blob) FROM clip_images WHERE clip_id = ?",
                    item.dbID
                )
                expect(
                    hex.hasPrefix("434C4950414531"),
                    "私密图片落盘为 CLIPAE1 密文（hex 前缀）"
                )
                expect(
                    store.imageData(for: item) == togglePNG,
                    "读取解密还原出原始字节"
                )
                store.togglePrivate(dbID: item.dbID)
                let plainHex = storedValue(
                    "SELECT hex(blob) FROM clip_images WHERE clip_id = ?",
                    item.dbID
                )
                expect(
                    !plainHex.hasPrefix("434C4950454531"),
                    "取消私密后还原明文"
                )
            } else {
                expect(false, "toggle 路径的 fixture 入库")
            }
            if let legacyItem = clipByHash(legacyPNG!) {
                store.sealPrivateImagesIfNeeded()
                let hex = storedValue(
                    "SELECT hex(blob) FROM clip_images WHERE clip_id = ?",
                    legacyItem.dbID
                )
                expect(
                    hex.hasPrefix("434C4950414531"),
                    "启动补加密把存量私密图片改写为密文"
                )
                expect(
                    store.imageData(for: legacyItem) == legacyPNG,
                    "补加密后读取仍还原出原始字节"
                )
            } else {
                expect(false, "迁移路径的 fixture 入库")
            }

            if let checkpoint = try? DatabaseConnection(path: dbURL.path) {
                _ = try? checkpoint.prepare("PRAGMA wal_checkpoint(TRUNCATE)") {
                    statement in
                    _ = sqlite3_step(statement)
                }
            }
            var rawBytes = (try? Data(contentsOf: dbURL)) ?? Data()
            rawBytes += (try? Data(contentsOf: URL(
                fileURLWithPath: dbURL.path + "-wal"
            ))) ?? Data()
            expect(
                !rawBytes.contains(Data(legacyPNG!.prefix(48))),
                "clips.sqlite 与 WAL 里都找不到私密图片的原始字节"
            )
            expect(
                rawBytes.contains(Data(publicPNG!.prefix(48))),
                "对照组：公开图片明文在文件里（证明扫描有效）"
            )
        }

        print("[CRYPTO] 检查 \(checks) 项，失败 \(failures) 项")
        if failures == 0 {
            print("[CRYPTO] OK")
        }
        return failures == 0 ? 0 : 1
    }

    @MainActor
    static func apiProbe() -> Int32 {
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition {
                print("[API] FAIL \(label)")
                failures += 1
            }
        }

        let root = ClipStore.defaultBaseDirectory()
        let settings = SettingsStore(
            defaults: UserDefaults(
                suiteName: "ClipaAPIProbe-\(UUID().uuidString)"
            )!
        )
        let store = ClipStore(baseDirectory: root, settingsStore: settings)
        guard store.database != nil else {
            print("[API] 打不开临时库")
            return 1
        }

        APITokenStore.shared.reload()
        APITokenStore.shared.revokeAll()
        let metaToken = try? APITokenStore.shared.create(
            label: "meta-only",
            scopes: [.searchMeta]
        )
        let fullToken = try? APITokenStore.shared.create(
            label: "full",
            scopes: [.searchMeta, .searchText, .readFull, .copy, .put, .note, .delete]
        )
        let textToken = try? APITokenStore.shared.create(
            label: "text-only",
            scopes: [.searchMeta, .searchText]
        )
        guard let metaToken, let fullToken, let textToken else {
            print("[API] 建令牌失败")
            return 1
        }

        let phone = "13113128089"
        let privatePhone = "13900139000"
        _ = store.insert(
            NewClip(
                kind: .text,
                text: "王工 手机 \(phone) 请存档",
                sourceApp: "Terminal"
            )
        )
        _ = store.insert(
            NewClip(
                kind: .text,
                text: "私密 \(privatePhone)",
                sourceApp: "Notes",
                isPrivate: true
            )
        )
        _ = store.insert(
            NewClip(
                kind: .text,
                text: "凭据 postgres://user:pass@host:5432/db",
                sourceApp: "Xcode",
                containsSensitive: true
            )
        )
        _ = store.insert(
            NewClip(
                kind: .file,
                text: "",
                fileURLs: [URL(fileURLWithPath: "/Users/someone/report.xlsx")],
                sourceApp: "Finder"
            )
        )

        let longBody = String(repeating: "甲乙丙丁戊己庚辛壬癸", count: 500)
        _ = store.insert(
            NewClip(
                kind: .text,
                text: longBody,
                contentHash: ContentHasher.hash(text: longBody)
            )
        )
        let longClip = store.items.first { $0.text == longBody }
        let privateClip = store.items.first { $0.isPrivate }
        let normalClip = store.items.first { $0.text.contains(phone) }
        expect(privateClip != nil, "夹具里有私密条目")
        expect(normalClip != nil, "夹具里有普通条目")

        var copiedClipID: UUID?
        let service = APIControlService(
            store: store,
            settings: settings,
            rootDirectory: root,
            copyClip: { clip in
                copiedClipID = clip.id
                return true
            }
        )

        func call(
            _ verb: String,
            token: String,
            id: String? = nil,
            query: String? = nil,
            text: String? = nil,
            note: String? = nil,
            label: String? = nil,
            limit: Int? = nil,
            offset: Int? = nil,
            schema: Int? = APIContract.protocolVersion
        ) -> APIResponse {
            var request = APIRequest()
            request.schema = schema
            request.token = token
            request.verb = verb
            request.args.id = id
            request.args.query = query
            request.args.text = text
            request.args.note = note
            request.args.label = label
            request.args.limit = limit
            request.args.offset = offset
            var result: APIResponse?
            Task { @MainActor in
                result = await service.handle(request, peer: "probe")
            }
            let deadline = Date().addingTimeInterval(10)
            while result == nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            return result ?? .failure(.internalError, "探针等待超时")
        }

        func code(_ response: APIResponse) -> String? {
            response.error?.code
        }

        expect(
            code(call("status", token: fullToken.secret)) == "not_enabled",
            "接口关闭时拒绝一切请求"
        )
        settings.apiControlEnabled = true

        expect(
            code(call("status", token: "clipa_wrong")) == "not_authorized",
            "错令牌 → not_authorized"
        )
        expect(
            code(call("status", token: fullToken.secret, schema: 99))
                == "version_mismatch",
            "协议版本不符 → version_mismatch"
        )

        let status = call("status", token: fullToken.secret)
        expect(status.ok && status.status?.tokenLabel == "full", "status 报出令牌身份")
        expect(
            status.status?.scopes.contains("put") == true
                && status.status?.writesAllowed == true,
            "status 报出作用域与写能力"
        )

        let metaSearch = call(
            "search",
            token: metaToken.secret,
            query: "王工",
            limit: 5
        )
        expect(metaSearch.ok, "meta 令牌可以检索")
        expect(
            (metaSearch.results ?? []).allSatisfy { $0.text.isEmpty },
            "meta 令牌拿不到任何正文"
        )
        expect(
            code(call("get", token: metaToken.secret, id: normalClip?.id.uuidString))
                == "not_authorized",
            "meta 令牌不能取单条"
        )

        expect(
            code(call("get", token: textToken.secret, id: normalClip?.id.uuidString))
                == "not_authorized",
            "search.text 令牌不能 get（缺 read.full）"
        )
        let textOnlySearch = call(
            "search",
            token: textToken.secret,
            query: "",
            limit: 50
        )
        expect(textOnlySearch.ok, "search.text 令牌可以检索")
        expect(
            (textOnlySearch.results ?? []).allSatisfy {
                $0.text.utf8.count <= APIRecord.Limits.bodyBytes
            },
            "search.text 令牌的正文仍是片段（≤ snippet 上限）"
        )
        if let longClip {
            let longGet = call(
                "get",
                token: fullToken.secret,
                id: longClip.id.uuidString
            )
            expect(
                longGet.ok
                    && longGet.clip?.text == longBody
                    && longGet.clip?.truncated == false,
                "read.full 令牌 get 长文返回整条（truncated=false）"
            )
        }

        let fullSearch = call(
            "search",
            token: fullToken.secret,
            query: "",
            limit: 50
        )
        let results = fullSearch.results ?? []
        let rawJSON = APIClientCLI.jsonString(for: fullSearch)
        expect(!results.isEmpty, "全权令牌能检索到条目")
        expect(
            !results.contains { $0.id == privateClip?.id.uuidString },
            "私密条目不在检索结果里"
        )

        expect(
            !rawJSON.contains(privatePhone),
            "私密条目的号码不在结果里"
        )
        expect(
            results.allSatisfy { $0.text.utf8.count <= 64 },
            "search 片段上限 64 字节（正文走 get）"
        )
        if let normalClip {
            expect(
                results.first { $0.id == normalClip.id.uuidString }?.redacted
                    == false,
                "记录里的 redacted 恒为 false"
            )
        }

        do {
            let prefix = "PagingProbe-\(UUID().uuidString.prefix(6))"
            for index in 0..<7 {
                let text = "\(prefix)-item-\(String(format: "%02d", index))"
                _ = store.insert(
                    NewClip(
                        kind: .text,
                        text: text,
                        sourceApp: "Probe",
                        contentHash: ContentHasher.hash(text: text)
                    )
                )
            }
            var collected: [String] = []
            var offset = 0
            var pages = 0
            var lastResponse: APIResponse?
            while pages < 10 {
                let page = call(
                    "search",
                    token: fullToken.secret,
                    query: prefix,
                    limit: 3,
                    offset: offset
                )
                lastResponse = page
                let ids = (page.results ?? []).map(\.id)
                collected += ids
                pages += 1
                guard let next = page.nextOffset, !ids.isEmpty else { break }
                offset = next
            }
            expect(collected.count == 7, "翻页收集到全部 7 条（\(collected.count)）")
            expect(
                Set(collected).count == 7,
                "翻页不重不漏（去重后 \(Set(collected).count)）"
            )
            expect(
                lastResponse?.nextOffset == nil,
                "最后一页没有 nextOffset"
            )
            expect(
                lastResponse?.total == 7,
                "total 报的是过滤后的总命中数（\(lastResponse?.total ?? -1)）"
            )
            let beyond = call(
                "search",
                token: fullToken.secret,
                query: prefix,
                limit: 3,
                offset: 100
            )
            expect(
                (beyond.results ?? []).isEmpty && beyond.nextOffset == nil,
                "越界 offset 返回空页而不是报错"
            )
            expect(
                beyond.total == 7,
                "空页照样给出 total（\(beyond.total ?? -1)）"
            )
        }

        if let privateClip {
            let denied = call(
                "get",
                token: fullToken.secret,
                id: privateClip.id.uuidString
            )
            let missing = call(
                "get",
                token: fullToken.secret,
                id: UUID().uuidString
            )
            expect(code(denied) == "not_found", "私密条目按不存在处理")
            expect(
                code(denied) == code(missing),
                "私密与不存在返回同一个错误码（不可区分）"
            )
        }

        if let normalClip {
            let prefix = String(normalClip.id.uuidString.prefix(8))
            let byPrefix = call("get", token: fullToken.secret, id: prefix)
            expect(byPrefix.ok, "id 前缀（8 位）能取到条目")
            expect(
                byPrefix.clip?.id.lowercased()
                    == normalClip.id.uuidString.lowercased(),
                "前缀取到的就是那一条"
            )
            expect(
                call("get", token: fullToken.secret, id: prefix.lowercased())
                    .clip?.id.lowercased()
                    == normalClip.id.uuidString.lowercased(),
                "前缀大小写不敏感"
            )
            expect(
                code(call("get", token: fullToken.secret, id: "00000000"))
                    == "not_found",
                "不存在的 id 前缀 → not_found"
            )
        }
        if let privateClip {
            expect(
                code(
                    call(
                        "get",
                        token: fullToken.secret,
                        id: String(privateClip.id.uuidString.prefix(8))
                    )
                ) == "not_found",
                "私密 id 的前缀同样按不存在处理（前缀不能让私密条目变得可探测）"
            )
        }
        expect(
            code(call("get", token: fullToken.secret, id: "not-a-uuid"))
                == "not_found",
            "匹配不到任何条目的 id → not_found（退出码与原先一致，仍是 1）"
        )

        let sharedPrefix = "AAAABBBB"
        let ambiguousIDs = [
            "\(sharedPrefix)-0000-0000-0000-000000000001",
            "\(sharedPrefix)-0000-0000-0000-000000000002",
        ].compactMap(UUID.init(uuidString:))
        for (offset, id) in ambiguousIDs.enumerated() {
            _ = store.insert(
                NewClip(
                    id: id,
                    kind: .text,
                    text: "歧义前缀夹具 \(offset)"
                )
            )
        }
        expect(ambiguousIDs.count == 2, "歧义夹具已建立（两条）")
        expect(
            code(call("get", token: fullToken.secret, id: sharedPrefix))
                == "bad_request",
            "前缀命中多条 → bad_request（不猜）"
        )
        _ = store.delete(ids: Set(ambiguousIDs))
        expect(
            code(call("get", token: fullToken.secret, id: sharedPrefix))
                == "not_found",
            "删掉歧义夹具后同一前缀变成 not_found（夹具已收尾）"
        )

        if let privateClip {
            copiedClipID = nil
            let response = call(
                "copy",
                token: fullToken.secret,
                id: privateClip.id.uuidString
            )
            expect(code(response) == "not_found", "copy 私密条目被拒")
            expect(copiedClipID == nil, "私密条目**没有**被送到写剪贴板的动作")
        }
        if let normalClip {
            copiedClipID = nil
            let response = call(
                "copy",
                token: metaToken.secret,
                id: normalClip.id.uuidString
            )
            expect(code(response) == "not_authorized", "缺 copy 作用域被拒")
            expect(copiedClipID == nil, "被拒时没有调用写剪贴板")
            copiedClipID = nil
            let allowed = call(
                "copy",
                token: fullToken.secret,
                id: normalClip.id.uuidString
            )
            expect(allowed.ok, "有作用域时 copy 成功")
            expect(copiedClipID == normalClip.id, "复制的是那条")
        }

        let putPlain = call(
            "put",
            token: fullToken.secret,
            text: "INTERNAL-TICKET-42"
        )

        expect(
            putPlain.ok,
            "put 不再被规则包拒绝（skip.md 已删除）"
        )
        settings.skipSensitive = true
        let sensitive = call(
            "put",
            token: fullToken.secret,
            text: "postgres://user:pass@host:5432/db"
        )
        expect(code(sensitive) == "denied", "put 敏感内容被拒（跳过开关开着）")
        settings.skipSensitive = false
        let before = store.items.count
        let inserted = call(
            "put",
            token: fullToken.secret,
            text: "来自 Agent 的一段内容",
            label: "Probe Agent"
        )
        expect(inserted.ok, "put 正常内容成功")
        expect(store.items.count == before + 1, "历史里多了一条")
        expect(
            store.items.first?.sourceApp == "Agent: Probe Agent",
            "来源标成 Agent: <label>"
        )
        expect(
            code(call("put", token: metaToken.secret, text: "x"))
                == "not_authorized",
            "缺 put 作用域被拒"
        )

        if let normalClip {
            expect(
                code(call("note", token: metaToken.secret, id: normalClip.id.uuidString, note: "x"))
                    == "not_authorized",
                "缺 note 作用域被拒"
            )
            let written = call(
                "note",
                token: fullToken.secret,
                id: normalClip.id.uuidString,
                note: "由探针写入"
            )
            expect(written.ok, "note 写入成功")
            expect(
                store.clip(id: normalClip.id)?.note == "由探针写入",
                "备注确实落库"
            )
        }

        let auditURL = APIAuditLog.url(rootDirectory: root)
        let auditText = (try? String(contentsOf: auditURL, encoding: .utf8)) ?? ""
        let entries = APIAuditLog.recent(200, rootDirectory: root)
        expect(!entries.isEmpty, "审计有记录")
        expect(
            entries.contains { $0.denied != nil },
            "被拒绝的调用也留了记录"
        )
        expect(
            !auditText.contains("INTERNAL-TICKET")
                && !auditText.contains("13113128089")
                && !auditText.contains("postgres://"),
            "审计里没有正文（含被拒内容的原文）"
        )
        expect(
            APITokenStore.shared.tokens.first { $0.id == fullToken.token.id }?
                .callCount ?? 0 > 0,
            "令牌的使用次数被记下来"
        )

        var limited = false
        for _ in 0..<(APIControlService.rateLimitPerMinute + 2) {
            let response = call("status", token: metaToken.secret)
            if code(response) == "rate_limited" {
                limited = true
                break
            }
        }
        expect(limited, "超过每分钟上限后被限流")

        let server = APIControlServer.shared
        APIControlServer.shared.start(
            store: store,
            settings: settings,
            rootDirectory: root
        )
        let socketURL = APIControlServer.socketURL(rootDirectory: root)
        expect(server.isRunning, "服务端已监听")
        expect(APIControlServer.canConnect(to: socketURL), "socket 可连接")
        expect(

            {
                let attributes = try? FileManager.default
                    .attributesOfItem(atPath: socketURL.path)
                let permissions = (attributes?[.posixPermissions] as? NSNumber)?
                    .intValue
                return permissions == 0o600
            }(),
            "socket 权限是 0600"
        )

        expect(
            SocketProtection.disableSigPipe(-1) == false,
            "坏 fd 上 SO_NOSIGPIPE 设置失败（守卫的假分支）"
        )
        let sigpipeProbeFD = socket(AF_UNIX, SOCK_STREAM, 0)
        expect(
            sigpipeProbeFD >= 0 && SocketProtection.disableSigPipe(sigpipeProbeFD),
            "真 socket 上 SO_NOSIGPIPE 设置成功"
        )
        if sigpipeProbeFD >= 0 { close(sigpipeProbeFD) }
        var wireRequest = APIRequest()
        wireRequest.schema = APIContract.protocolVersion
        wireRequest.token = fullToken.secret
        wireRequest.verb = "status"

        var wire: APIResponse?
        DispatchQueue.global().async {
            wire = APIClientCLI.send(
                wireRequest,
                to: socketURL,
                timeout: 5
            )
        }
        let wireDeadline = Date().addingTimeInterval(10)
        while wire == nil, Date() < wireDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        expect(
            wire?.status?.tokenLabel == "full",
            "socket 往返拿到了 status（走完整协议）"
        )
        if let wire {
            let json = APIClientCLI.jsonString(for: wire)
            expect(
                json.contains("\"ok\" : true") || json.contains("\"ok\": true")
                    || json.contains("\"ok\""),
                "响应是合法 JSON"
            )
        }
        server.stop()
        expect(
            !FileManager.default.fileExists(atPath: socketURL.path),
            "停止后 socket 文件被删除"
        )

        print("[API] 检查 \(checks) 项")
        print(
            failures == 0
                ? "[API] OK"
                : "[API] \(failures) failure(s)"
        )

        APITokenStore.shared.revokeAll()

        do {
            let deleteToken = try? APITokenStore.shared.create(
                label: "delete-probe",

                scopes: [.searchMeta, .searchText, .readFull, .delete]
            )
            if let normalClip, let deleteToken {
                expect(
                    code(call("delete", token: metaToken.secret, id: normalClip.id.uuidString))
                        == "not_authorized",
                    "delete 无作用域 → not_authorized"
                )
                let negative = call(
                    "delete",
                    token: deleteToken.secret,
                    id: normalClip.id.uuidString
                )
                expect(negative.ok, "带 delete 作用域时可删除普通条目")
            }
            let deleteReader = deleteToken
            let doomedText = "DeleteProbe-\(UUID().uuidString.prefix(6))"
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: doomedText,
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: doomedText)
                )
            )
            let doomedSearch = call(
                "search",
                token: deleteReader?.secret ?? fullToken.secret,
                query: doomedText,
                limit: 5
            )
            if let doomedID = (doomedSearch.results ?? []).first?.id,
               let deleteReader {
                expect(
                    call("delete", token: deleteReader.secret, id: doomedID).ok,
                    "有作用域时 delete 成功"
                )
                expect(

                    code(call("get", token: deleteReader.secret, id: doomedID))
                        == "not_found",
                    "删除后这条真的不存在了"
                )
            } else {
                expect(false, "待删条目能被检索到")
            }
            if let privateClip, let deleteReader {
                expect(
                    code(call("delete", token: deleteReader.secret, id: privateClip.id.uuidString))
                        == "not_found",
                    "私密条目对 delete 同样按不存在处理"
                )
            }
        }

        APIAuditLog.clear(rootDirectory: root)
        return failures == 0 ? 0 : 1
    }

    private struct ProbeEnvelope: Decodable {
        let schema: Int
        let count: Int
        let truncated: Bool
        let redactionRules: Int
        let generatedAt: String
        let clips: [ProbeClip]

        struct ProbeClip: Decodable {
            let id: String
            let kind: String
            let sensitive: Bool
            let redacted: Bool
            let truncated: Bool
            let text: String
        }
    }

    @MainActor

    static func mcpProbe() -> Int32 {
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition {
                print("[MCP] FAIL \(label)")
                failures += 1
            }
        }

        func rpc(_ line: String) -> [String: Any]? {
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: CommandLine.arguments[0]
            )
            process.arguments = ["--mcp-stdio"]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            input.fileHandleForWriting.write(Data((line + "\n").utf8))
            input.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let first = data.split(separator: 0x0A).first,
                  let object = try? JSONSerialization.jsonObject(
                      with: Data(first)
                  ) as? [String: Any] else {

                print(
                    "[MCP] raw(<\(data.count)B, term=\(process.terminationStatus))="
                        + (String(data: data.prefix(400), encoding: .utf8) ?? "非UTF-8")
                )
                return nil
            }
            return object
        }

        let initObject = rpc(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        )
        let initResult = initObject?["result"] as? [String: Any]
        expect(
            initResult?["protocolVersion"] as? String == "2025-06-18",
            "initialize 回双方都认识的协议版本"
        )
        expect(
            (initResult?["serverInfo"] as? [String: Any])?["name"]
                as? String == "clipa",
            "serverInfo.name 是 clipa"
        )

        let listObject = rpc(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = ((listObject?["result"] as? [String: Any])?["tools"]
            as? [[String: Any]]) ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        expect(
            names == [
                "clipa_status", "search_clips", "get_clip",
                "copy_clip", "put_clip", "add_note", "delete_clip",
            ],
            "工具清单与七个动词一一对应（\(names.sorted())）"
        )

        let callObject = rpc(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"clipa_status","arguments":{}}}"#
        )
        let callResult = callObject?["result"] as? [String: Any]
        let content = (callResult?["content"] as? [[String: Any]])?
            .first?["text"] as? String
        let envelope = content.flatMap {

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(
                APIResponse.self,
                from: Data($0.utf8)
            )
        }
        expect(envelope != nil, "tools/call 带回可解析的 APIResponse 包络")

        let gateCodes: Set<String> = [
            APIErrorCode.notEnabled.rawValue,
            APIErrorCode.notAuthorized.rawValue,
        ]
        expect(
            envelope != nil
                && (envelope?.ok == true
                    || gateCodes.contains(envelope?.error?.code ?? "")),
            "tools/call 走到了真实策略层（code=\(envelope?.error?.code ?? "nil") ok=\(envelope?.ok ?? false)）"
        )
        expect(
            callResult?["isError"] as? Bool == !(envelope?.ok ?? true),
            "isError 与包络的 ok 一致"
        )

        let unknown = rpc(#"{"jsonrpc":"2.0","id":4,"method":"no/such"}"#)
        expect(
            (unknown?["error"] as? [String: Any])?["code"] as? Int == -32601,
            "未知方法返回 -32601"
        )

        let broken = rpc("this is not json")
        expect(
            (broken?["error"] as? [String: Any])?["code"] as? Int == -32700,
            "坏 JSON 返回 -32700"
        )

        print("[MCP] \(failures == 0 ? "OK" : "FAILED") 检查 \(checks) 项")
        return failures == 0 ? 0 : 1
    }

    @MainActor
    static func menuStructureProbe() -> Int32 {
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition {
                print("[MENU] FAIL \(label)")
                failures += 1
            }
        }
        func titles(_ menu: NSMenu) -> [String] {
            menu.items
                .filter { !$0.isSeparatorItem && !$0.isHidden }
                .map(\.title)
        }

        let settings = SettingsStore.shared
        let menu = AppDelegate().statusMenuSnapshot()

        let top = titles(menu)
        print("[MENU] 顶级项: " + top.joined(separator: " | "))

        expect(
            !top.contains("忽略当前前台应用"),
            "顶级项不再有单独的“忽略当前前台应用”"
        )
        expect(!top.contains("已忽略的应用"), "顶级项不再有单独的“已忽略的应用”")
        expect(!top.contains("跳过规则"), "顶级项不再有单独的“跳过规则”")
        let module = menu.items.first { $0.title == "忽略与跳过" }
        expect(module?.submenu != nil, "存在合并后的“忽略与跳过”子菜单")

        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            expect(
                !submenu.autoenablesItems,
                "子菜单「\(item.title)」关闭了自动启用"
            )
        }

        guard let rules = module?.submenu else {
            print("[MENU] 读不到子菜单，结构断言到此为止")
            print("[MENU] \(failures == 0 ? "OK" : "FAILED") 检查 \(checks) 项")
            return failures == 0 ? 0 : 1
        }
        let ruleTitles = titles(rules)
        print("[MENU] 忽略与跳过: " + ruleTitles.joined(separator: " | "))

        let expectedRules: [(String, KeyPath<SettingsStore, Bool>)] = [
            ("跳过标记为机密的复制内容", \.skipConfidentialPasteboard),
            ("跳过疑似敏感内容", \.skipSensitive),
            ("跳过密码管理器复制的内容", \.ignorePasswordManagers)
        ]
        for (title, flag) in expectedRules {
            let item = rules.items.first { $0.title == title }
            expect(item != nil, "有规则「\(title)」")
            guard let item else { continue }
            expect(
                (item.state == .on) == settings[keyPath: flag],
                "「\(title)」勾选与偏好一致（item=\(item.state == .on)"
                    + " store=\(settings[keyPath: flag])）"
            )
            expect(item.isEnabled, "规则「\(title)」可点")
        }
        expect(
            !ruleTitles.contains("自动跳过密码管理器"),
            "密码管理器规则不再藏在应用清单里"
        )

        let target = rules.items.first {
            $0.title.hasPrefix("忽略") || $0.title.hasPrefix("已忽略")
                || $0.title.hasPrefix("无法忽略")
        }
        expect(target != nil, "有“忽略当前前台应用”那一行")
        if let target {
            print(
                "[MENU] 目标行: \(target.title)"
                    + " enabled=\(target.isEnabled)"
                    + " id=\(target.representedObject as? String ?? "-")"
            )
            expect(
                target.isEnabled == (target.representedObject != nil),
                "该行可点当且仅当带着要忽略的 bundle id"
            )
            if let bundleID = target.representedObject as? String {
                expect(
                    !settings.ignoredApps.contains(bundleID),
                    "可点的那一行不指向已在清单里的应用"
                )
            }
        }

        let removals = rules.items.filter { $0.title.hasPrefix("不再忽略") }
        expect(
            removals.count == settings.ignoredApps.count,
            "清单条数与偏好一致（\(removals.count) vs "
                + "\(settings.ignoredApps.count)）"
        )
        if settings.ignoredApps.isEmpty {
            let empty = rules.items.first { $0.title.contains("还没有手动忽略") }
            expect(empty != nil, "清单为空时给出说明")
            expect(empty?.isEnabled == false, "说明本身不可点")
        } else {
            expect(
                removals.allSatisfy {
                    ($0.representedObject as? String) != nil
                },
                "每条清单项都带着自己的 bundle id"
            )
        }

        let clearMenu = menu.items.first { $0.title == "清空历史" }?.submenu
        expect(clearMenu != nil, "存在「清空历史」子菜单")
        let limitItem = clearMenu?.items.first {
            $0.title.hasPrefix("历史条数上限：")
        }
        expect(limitItem != nil, "有「历史条数上限」条目")
        expect(
            limitItem?.title
                == AppDelegate.historyLimitMenuTitle(limit: settings.historyLimit),
            "上限标题与当前偏好一致（item=\(limitItem?.title ?? "nil")）"
        )
        expect(limitItem?.isEnabled == true, "「历史条数上限」可点")
        let autoPauseItem = clearMenu?.items.first {
            $0.title == "达到上限时自动暂停记录"
        }
        expect(autoPauseItem != nil, "有「达到上限时自动暂停记录」条目")
        expect(
            autoPauseItem?.state == (settings.autoPauseAtLimit ? .on : .off),
            "自动暂停勾选与偏好一致"
        )

        print("[MENU] \(failures == 0 ? "OK" : "FAILED") 检查 \(checks) 项")
        return failures == 0 ? 0 : 1
    }

    @MainActor
    static func panelPresentationProbe() -> Int32 {
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition {
                print("[PANEL] FAIL \(label)")
                failures += 1
            }
        }

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let target = QuickStripController.panelFrame(in: screen)
        let start = QuickStripController.startFrame(for: target)
        print(
            "[PANEL] quick strip (centered): frame=\(target) screen=\(screen)"
                + " inside=\(screen.contains(target))"
        )

        expect(
            abs(target.midX - screen.midX) < 0.5
                && abs(target.midY - screen.height * 0.54) < 0.5
                && target.width >= 480 && target.width <= 640
                && screen.contains(target),
            "面板居中浮动（水平居中，垂直中心 54%）"
        )
        expect(
            start.minY == target.minY - 48
                && start.width == target.width
                && start.height == target.height,
            "滑入起点在静止位置下方 48pt"
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClipaPanelProbe-\(UUID().uuidString)",
                isDirectory: true
            )
        let settings = SettingsStore(
            defaults: UserDefaults(
                suiteName: "ClipaPanelProbe-\(UUID().uuidString)"
            )!

        )
        let store = ClipStore(baseDirectory: dir, settingsStore: settings)
        for index in 1...8 {
            let text = "panel-probe-\(index)"
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: text,
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: text)
                )
            )
        }
        let controller = QuickStripController(
            viewModel: PanelViewModel(store: store, settings: settings)
        )
        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let resting = QuickStripController.panelFrame(in: screen)
        print(
            "[PANEL] quick strip slide: rest=\(controller.windowFrame)"
                + " expected=\(resting)"
        )
        expect(controller.isVisible, "show() 之后面板可见")
        expect(
            controller.windowFrame == resting,
            "静止位置 = 计算的居中浮动态"
        )
        expect(
            abs(controller.windowFrame.width - target.width) < 1,
            "窗口宽度 = 计算宽度"
        )

        func effectViews(in view: NSView) -> [NSView] {
            var found = view.subviews.filter {
                String(describing: type(of: $0)).contains("GlassEffectView")
                    || $0 is NSVisualEffectView
            }
            for subview in view.subviews {
                found += effectViews(in: subview)
            }
            return found
        }
        let paneView = controller.contentWindow.contentView
        let effects = paneView.map(effectViews(in:)) ?? []
        let glass = effects.contains {
            String(describing: type(of: $0)).contains("GlassEffectView")
        }
        let legacyBlur = effects
            .compactMap { $0 as? NSVisualEffectView }
            .contains {
                $0.blendingMode == NSVisualEffectView.BlendingMode.behindWindow
            }
        print(
            "[PANEL] quick strip backdrop: liquidGlass=\(glass)"
                + " legacyBlur=\(legacyBlur) views=\(effects.count)"
        )
        expect(glass || legacyBlur, "底板是窗口后模糊 / 液态玻璃")

        let cardIDs = Array(controller.viewModel.navigationOrder.prefix(8))
        expect(cardIDs.count >= 6, "面板拿到了夹具行（\(cardIDs.count)）")

        if cardIDs.count >= 3,
           let third = store.clip(id: cardIDs[2]) {
            controller.viewModel.select(third)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let point = NSPoint(
                x: controller.windowFrame.width / 2,
                y: controller.windowFrame.height
                    - QuickStripView.rowCenterY(
                        index: 2,
                        in: controller.windowFrame.height
                    )
            )
            sendClick(
                at: point,
                to: controller.contentWindow,
                modifierFlags: []
            )
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let selected = controller.viewModel.selectedItem?.text ?? "nil"
            print(
                "[PANEL] quick strip mouse click: selected=\(selected)"
                    + " expected=\(third.text)"
            )
            expect(controller.viewModel.selectedID == third.id, "点第三张卡片即选中它")
        }

        if let editor = controller.contentWindow.firstResponder as? NSTextView,
           !editor.hasMarkedText() {
            controller.viewModel.query = ""
            editor.string = ""
            editor.insertText("ab", replacementRange: editor.selectedRange())
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let query = controller.viewModel.query
            let caret = editor.selectedRange().location
            print(
                "[PANEL] quick strip typing: query=\"\(query)\" caret=\(caret)"
                    + " surface=\(String(describing: controller.viewModel.activeSurface))"
            )
            expect(query == "ab" && caret == 2, "输入进搜索框且光标停在末尾")
            controller.viewModel.query = ""
            controller.viewModel.queryDidChange()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        } else {
            print("[PANEL] quick strip typing: skipped (无字段编辑器)")
        }

        if let first = cardIDs.first, let clip = store.clip(id: first) {
            controller.viewModel.select(clip)
            controller.viewModel.openNoteEditor(clip)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let editing = controller.viewModel.showNoteEditor
            let returnToField = PanelKeyRouter(
                isTextEditorOpen: editing,
                isComposingText: false
            ).action(keyCode: 36, modifiers: []) == .passThrough
            print(
                "[PANEL] note editor keys: editing=\(editing)"
                    + " returnToField=\(returnToField)"
                    + " visible=\(controller.isVisible)"
                    + " keyWindow=\(controller.contentWindow.isKeyWindow)"
            )
            expect(
                editing && returnToField && controller.isVisible,
                "备注编辑器打开时 Return 归输入框、面板不收起"
            )
            if controller.contentWindow.isKeyWindow {
                sendKey(keyCode: 53, to: controller.contentWindow)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                print(
                    "[PANEL] note editor esc: editing="
                        + "\(controller.viewModel.showNoteEditor)"
                )
                expect(
                    !controller.viewModel.showNoteEditor,
                    "esc 关闭备注编辑器"
                )
            } else {
                controller.viewModel.showNoteEditor = false
                print("[PANEL] note editor esc: skipped (窗口不是 key window)")
            }
        }

        controller.hide()
        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        print(
            "[PANEL] quick strip re-open during hide:"
                + " visible=\(controller.isVisible)"
        )
        expect(controller.isVisible, "收起动画中途再唤出仍是可见的")

        controller.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        try? FileManager.default.removeItem(at: dir)
        print(
            failures == 0
                ? "[PANEL] OK"
                : "[PANEL] \(failures) failure(s)"
        )
        return failures == 0 ? 0 : 1
    }

    @MainActor
    private static func sendClick(
        at point: NSPoint,
        to window: NSWindow,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ) else { continue }
            window.sendEvent(event)
        }
    }

    @MainActor
    private static func sendKey(keyCode: UInt16, to window: NSWindow) {
        NSApp.sendEvent(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: keyCode == 53 ? "\u{1b}" : "\r",
                charactersIgnoringModifiers: keyCode == 53 ? "\u{1b}" : "\r",
                isARepeat: false,
                keyCode: keyCode
            ) ?? NSApplication.shared.currentEvent ?? NSApplication.shared.currentEvent!
        )
    }

    @MainActor
    static func panelRetentionProbe() -> Int32 {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if !condition {
                print("[PANELRET] FAIL \(label)")
                failures += 1
            }
        }
        func makeStore(_ tag: String) -> ClipStore {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaRetention-\(tag)-\(UUID().uuidString)",
                    isDirectory: true
                )
            let settings = SettingsStore(
                defaults: UserDefaults(
                    suiteName: "ClipaRetention-\(tag)-\(UUID().uuidString)"
                )!

            )
            return ClipStore(baseDirectory: dir, settingsStore: settings)
        }

        weak var weakModel: PanelViewModel?
        weak var weakBoundStore: ClipStore?
        do {
            let store = makeStore("host")
            weakBoundStore = store
            let model = PanelViewModel(store: store)
            weakModel = model

            autoreleasepool {
                let hosting = NSHostingView(rootView: QuickStripView(vm: model))
                hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 306)
                hosting.layoutSubtreeIfNeeded()
            }
            print(
                "[PANELRET] 仅宿主视图：model="
                    + (weakModel == nil ? "已释放" : "仍存活")
                    + " store=" + (weakBoundStore == nil ? "已释放" : "仍存活")
            )
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        expect(weakModel == nil, "宿主视图释放后 view model 也释放")
        expect(weakBoundStore == nil, "view model 释放后它持有的 store 也释放")
        print(
            "[PANELRET] after scope: model="
                + (weakModel == nil ? "已释放" : "仍存活")
                + " store=" + (weakBoundStore == nil ? "已释放" : "仍存活")
        )

        let panel = QuickStripController(
            viewModel: PanelViewModel(store: makeStore("first"))
        )
        weak var weakOldStore = panel.viewModel.store
        let second = makeStore("second")
        panel.viewModel.rebind(store: second)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let oldStore = weakOldStore
        print(
            "[PANELRET] 修复：rebind 后: panel=仍存活 store="
                + (oldStore == nil ? "已释放" : "仍存活")
        )
        expect(oldStore == nil, "rebind 之后旧工作区被释放")
        expect(panel.viewModel.store === second, "rebind 之后模型指向新工作区")

        let sharedBefore = ClipStore.shared
        let third = makeStore("third")
        ClipStore.replaceShared(with: third)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        expect(
            panel.viewModel.store === third,
            "替换 ClipStore.shared 后面板自动跟随新工作区"
        )
        ClipStore.replaceShared(with: sharedBefore)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        expect(
            panel.viewModel.store === sharedBefore,
            "恢复 ClipStore.shared 后面板同样跟随回去"
        )

        print(
            failures == 0
                ? "[PANELRET] OK"
                : "[PANELRET] \(failures) failure(s)"
        )
        return failures == 0 ? 0 : 1
    }

    @MainActor
    static func panelMemoryProbe(directory: URL?) -> Int32 {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print("[PANELMEM] \(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        let empty = ClipStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaPanelMemoryEmpty-\(UUID().uuidString)",
                    isDirectory: true
                ),
            settingsStore: SettingsStore(
                defaults: UserDefaults(
                    suiteName: "ClipaPanelMemory-\(UUID().uuidString)"
                )!

            )
        )
        let big = directory.map { ClipStore(baseDirectory: $0) } ?? empty
        let controller = QuickStripController(
            viewModel: PanelViewModel(store: empty)
        )
        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        expect(
            controller.viewModel.navigationOrder.isEmpty,
            "空工作区打开时没有行"
        )

        for round in 1...3 {
            weak var weakOld = controller.viewModel.store
            controller.viewModel.rebind(store: big)
            var deadline = Date().addingTimeInterval(30)
            while controller.viewModel.navigationOrder.count != big.items.count,
                  Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            expect(
                controller.viewModel.navigationOrder.count == big.items.count,
                "第 \(round) 轮列表行数跟新工作区一致（\(controller.viewModel.navigationOrder.count) / \(big.items.count)）"
            )
            controller.viewModel.rebind(store: empty)
            deadline = Date().addingTimeInterval(20)
            while !controller.viewModel.navigationOrder.isEmpty,
                  Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            expect(
                controller.viewModel.navigationOrder.isEmpty,
                "第 \(round) 轮切回空工作区后列表清空（\(controller.viewModel.navigationOrder.count) 行）"
            )
            let old = weakOld
            _ = old
        }
        controller.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print(
            failures == 0
                ? "[PANELMEM] OK"
                : "[PANELMEM] \(failures) failure(s)"
        )
        return failures == 0 ? 0 : 1
    }

    @MainActor
    static func compareProbe() -> Int32 {
        var failures = 0
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClipaCompareProbe-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = ClipStore(
            baseDirectory: dir,
            settingsStore: SettingsStore(
                defaults: UserDefaults(
                    suiteName: "ClipaCompareProbe-\(UUID().uuidString)"
                )!

            )
        )
        let samples = [
            "kubernetes deployment rollback",
            "docker network inspect bridge",
            "本周的 json 配置",
            "apiVersion: apps/v1",
            "random note about lunch",
            "KUBERNETES in upper case"
        ]
        for (index, text) in samples.enumerated() {
            _ = store.insert(
                NewClip(
                    kind: .text,
                    text: text,
                    sourceApp: "Probe",
                    contentHash: ContentHasher.hash(text: "compare-\(index)")
                )
            )
        }
        let engine = LocalSearchEngine(
            database: store.database,
            store: store
        )
        for query in ["kubernetes", "docker", "network"] {
            let fast = engine.search(
                query: query,
                filter: SearchFilter(),
                store: store
            )
            let needle = query.lowercased()
            let brute = store.items.filter {
                $0.text.lowercased().contains(needle)
            }
            let parity = Set(fast.clips.map(\.id)) == Set(brute.map(\.id))
            print(
                "[COMPARE] query=\(query) fast=\(fast.clips.count)"
                    + " brute=\(brute.count) parity=\(parity)"
            )
            if !parity { failures += 1 }
        }

        let tagged = engine.search(
            query: "json",
            filter: SearchFilter(),
            store: store
        )
        let expectedTagged = store.items.filter { $0.smartTag == .json }
        let tagParity = Set(tagged.clips.map(\.id))
            == Set(expectedTagged.map(\.id))
        print(
            "[COMPARE] query=json (smart tag) fast=\(tagged.clips.count)"
                + " expected=\(expectedTagged.count) parity=\(tagParity)"
        )
        if !tagParity { failures += 1 }

        try? FileManager.default.removeItem(at: dir)
        print(
            failures == 0
                ? "[COMPARE] OK"
                : "[COMPARE] \(failures) failure(s)"
        )
        return failures == 0 ? 0 : 1
    }

    @MainActor
    static func captureEvaluateProbe() -> Int32 {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print("[CAPTURE-EVAL] \(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClipaCaptureProbe-\(UUID().uuidString)",
                isDirectory: true
            )
        let settings = SettingsStore(
            defaults: UserDefaults(
                suiteName: "ClipaCaptureProbe-\(UUID().uuidString)"
            )!

        )
        settings.pauseRecording = false
        settings.skipSensitive = false
        settings.skipConfidentialPasteboard = true
        let store = ClipStore(baseDirectory: dir, settingsStore: settings)
        let monitor = ClipboardMonitor.shared

        func board(_ name: String) -> NSPasteboard {
            NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaCaptureProbe-\(name)-\(UUID().uuidString)"
                )
            )
        }
        func evaluate(
            _ pasteboard: NSPasteboard,
            front: String? = "com.apple.TextEdit",
            source: String? = "TextEdit"
        ) -> ClipboardMonitor.CaptureDecision {
            monitor.evaluate(
                pasteboard: pasteboard,
                frontBundleID: front,
                sourceName: source,
                settings: settings,
                store: store
            )
        }

        let text = board("text")
        text.clearContents()
        text.setString("capture probe text", forType: .string)
        let textDecision = evaluate(text)
        if case .captured(let draft) = textDecision {
            print(
                "[CAPTURE-EVAL] captured kind=\(draft.kind.rawValue)"
                    + " length=\(draft.text.count) source=\(draft.sourceApp ?? "nil")"
            )
            expect(draft.kind == .text && draft.text == "capture probe text", "文本被捕获")
        } else {
            expect(false, "文本应被捕获，实际 \(textDecision)")
        }

        let image = board("image")
        image.clearContents()
        if let png = Self.makeProbePNG(width: 32, height: 24) {
            image.setData(png, forType: .png)
        }
        let imageDecision = evaluate(image, front: "com.apple.Preview", source: "Preview")
        if case .captured(let draft) = imageDecision {
            print("[CAPTURE-EVAL] captured kind=\(draft.kind.rawValue)")
            expect(draft.kind == .image, "图片被捕获")
        } else {
            expect(false, "图片应被捕获，实际 \(imageDecision)")
        }

        let concealed = board("concealed")
        concealed.clearContents()
        concealed.setString("secret", forType: .string)
        concealed.setData(
            Data("1".utf8),
            forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        )

        let concealedDecision = evaluate(
            concealed,
            front: "com.example.secret-tool",
            source: "SecretTool"
        )
        print("[CAPTURE-EVAL] \(concealedDecision)")
        expect(
            concealedDecision == ClipboardMonitor.CaptureDecision.confidentialSkipped,
            "打了机密标记的内容被跳过"
        )

        settings.skipSensitive = true
        let sensitive = board("sensitive")
        sensitive.clearContents()
        sensitive.setString(
            "sk-0123456789abcdef0123456789abcdef",
            forType: .string
        )
        let sensitiveDecision = evaluate(sensitive)
        print("[CAPTURE-EVAL] \(sensitiveDecision)")
        expect(
            sensitiveDecision == ClipboardMonitor.CaptureDecision.sensitiveSkipped,
            "敏感内容在开关打开时被跳过"
        )
        settings.skipSensitive = false

        let empty = board("empty")
        empty.clearContents()
        let emptyDecision = evaluate(empty)
        print("[CAPTURE-EVAL] \(emptyDecision)")
        expect(
            emptyDecision == ClipboardMonitor.CaptureDecision.noContent,
            "空剪贴板什么都不做"
        )

        try? FileManager.default.removeItem(at: dir)
        print(
            failures == 0
                ? "[CAPTURE-EVAL] OK"
                : "[CAPTURE-EVAL] \(failures) failure(s)"
        )
        return failures == 0 ? 0 : 1
    }

    @MainActor
    static func classificationPerfProbe() -> Int32 {
        var failures = 0
        let corpus: [(SmartTag, String)] = [
            (.json, #"{"a":1,"b":[2,3]}"#),
            (.json, #"[{"id":1},{"id":2}]"#),
            (.yaml, "apiVersion: v1\nkind: Pod\nmetadata:\n  name: nginx\n"),
            (.yaml, "services:\n  web:\n    image: nginx\n  db:\n    image: postgres\n"),
            (.markdown, "# 标题\n\n- 列表项\n\n> 引用\n"),
            (.markdown, "## 二级标题\n\n1. 第一\n2. 第二\n"),
            (.text, "kubernetes deployment rollback finished"),
            (.text, "https://www.swift.org/documentation/"),
            (.text, "docker network inspect bridge")
        ]
        let started = Date()
        var correct = 0
        var mismatches: [String] = []
        for (expected, text) in corpus {
            let tag = ClassificationEngine.classify(text) ?? .text
            if tag == expected {
                correct += 1
            } else {
                mismatches.append("\(expected.rawValue)←\(tag.rawValue)")
            }
        }
        let elapsed = Date().timeIntervalSince(started) * 1000
        print(
            "[CLASSPERF] corpus=\(corpus.count) correct=\(correct)"
                + String(format: " elapsed=%.1fms", elapsed)
                + (mismatches.isEmpty ? "" : " mismatches=\(mismatches.joined(separator: ","))")
        )
        if correct != corpus.count { failures += 1 }

        let long = String(repeating: "apiVersion: v1\nkind: Pod\n", count: 200)
        let longStart = Date()
        let longTag = ClassificationEngine.classify(long) ?? .text
        let longMS = Date().timeIntervalSince(longStart) * 1000
        print(
            "[CLASSPERF] long chars=\(long.count) tag=\(longTag.rawValue)"
                + String(format: " elapsed=%.1fms", longMS)
        )
        if longTag != .yaml { failures += 1 }
        if longMS > 3_000 { failures += 1 }

        print(
            failures == 0
                ? "[CLASSPERF] OK"
                : "[CLASSPERF] \(failures) failure(s)"
        )
        return failures == 0 ? 0 : 1
    }

final class LoopbackConnectionProbe: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private let lock = NSLock()
    private var running = false
    private var connections = 0
    let port: UInt16

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        var actual = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &size)
            }
        }
        guard named == 0 else {
            close(fd)
            return nil
        }
        listenFD = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        let fd = listenFD
        let worker = Thread { [weak self] in
            while self?.isRunning == true {
                var descriptor = pollfd(
                    fd: fd,
                    events: Int16(POLLIN),
                    revents: 0
                )
                guard poll(&descriptor, 1, 200) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                self?.noteConnection()
                close(client)
            }
        }
        worker.stackSize = 256 * 1024
        thread = worker
        worker.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func noteConnection() {
        lock.lock()
        connections += 1
        lock.unlock()
    }
}
}
