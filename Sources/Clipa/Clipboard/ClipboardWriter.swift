import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes clipboard content. The snapshot helper is used by self-tests so they
/// can restore the user's clipboard after exercising the system pasteboard.
///
/// Image/file payloads first pass a unified asset availability check so a
/// missing file never reports a successful copy.
final class ClipboardWriter {
    static let shared = ClipboardWriter()

    private struct PreparedImageCopy: Sendable {
        let data: Data
        let type: NSPasteboard.PasteboardType
        let pngFallback: Data?
    }

    /// Convenience for callers that already have a plain string (the
    /// format-conversion menu). The panel's own copy path goes through
    /// `PanelViewModel`, which applies the private-content gate first.
    @discardableResult
    static func copy(_ content: String) -> Bool {
        shared.copyText(content)
    }

    private var monitor: ClipboardMonitor { .shared }

    struct PasteboardSnapshot {
        let changeCount: Int
        let payloads: [(type: NSPasteboard.PasteboardType, data: Data)]

        static func current() -> PasteboardSnapshot? {
            let pb = NSPasteboard.general
            var payloads: [(NSPasteboard.PasteboardType, Data)] = []
            for type in pb.types ?? [] {
                if let data = pb.data(forType: type) {
                    payloads.append((type, data))
                }
            }
            guard !payloads.isEmpty else { return nil }
            return PasteboardSnapshot(changeCount: pb.changeCount, payloads: payloads)
        }

        func restore() {
            let pb = NSPasteboard.general
            pb.clearContents()
            for payload in payloads {
                pb.setData(payload.data, forType: payload.type)
            }
        }
    }

    @discardableResult
    func copy(
        _ item: Clip,
        store: ClipStore = .shared,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard store.assetAvailability(for: item) == .available else {
            return false
        }
        let pb = pasteboard
        if pb === NSPasteboard.general {
            monitor.flushPendingCapture()
        }
        var written = false
        switch item.kind {
        case .image:
            guard let data = store.imageData(for: item) else { return false }
            let prepared = Self.preparedImage(item: item, data: data)
            pb.clearContents()
            guard pb.setData(prepared.data, forType: prepared.type) else {
                return false
            }
            written = true
            // The original format is what modern targets receive. A PNG
            // fallback keeps targets that only ask for PNG working.
            if let png = prepared.pngFallback {
                _ = pb.setData(png, forType: .png)
            }
        case .file:
            guard !item.fileURLs.isEmpty else { return false }
            pb.clearContents()
            written = pb.writeObjects(item.fileURLs as [NSURL])
            // Finder also publishes the path(s) as text. Without it a text
            // target — a chat box, a note, a terminal — pastes nothing at all,
            // because the pasteboard only carries a file URL.
            if written {
                _ = pb.setString(
                    item.fileURLs.map(\.path).joined(separator: "\n"),
                    forType: .string
                )
            }
        default:
            pb.clearContents()
            written = pb.setString(item.text, forType: .string)
        }
        if written, pb === NSPasteboard.general {
            monitor.ignoreNextChange()
        }
        return written
    }

    /// UI-path clipboard copy. Pasteboard access still happens on the main
    /// thread (NSPasteboard is not safe off-thread), but image bytes are read
    /// and converted on a background task first so large images never stall
    /// the UI.
    @MainActor
    func copyAsync(
        _ item: Clip,
        store: ClipStore = .shared,
        to pasteboard: NSPasteboard = .general
    ) async -> Bool {
        // Async twins throughout: this runs inside a `Task`, and the blocking
        // bridges would hold a cooperative thread while waiting for a task that
        // needs one — the deadlock that froze the app on an image-heavy store.
        guard await store.assetAvailabilityAsync(for: item) == .available else {
            return false
        }
        let pb = pasteboard
        if pb === NSPasteboard.general {
            monitor.flushPendingCapture()
        }
        var written = false
        switch item.kind {
        case .image:
            // The blob read awaits the database actor; the PNG fallback
            // conversion is pure CPU work and stays off the main actor.
            guard let data = await store.imageDataAsync(for: item) else {
                return false
            }
            let prepared = await Task.detached(
                priority: .userInitiated
            ) { () -> PreparedImageCopy in
                Self.preparedImage(item: item, data: data)
            }.value
            // The file read happened off-thread; recapture anything that was
            // copied externally while we were reading before we overwrite it.
            if pb === NSPasteboard.general {
                monitor.flushPendingCapture()
            }
            pb.clearContents()
            guard pb.setData(prepared.data, forType: prepared.type) else {
                return false
            }
            written = true
            if let png = prepared.pngFallback {
                _ = pb.setData(png, forType: .png)
            }
        case .file:
            guard !item.fileURLs.isEmpty else { return false }
            pb.clearContents()
            written = pb.writeObjects(item.fileURLs as [NSURL])
            // See `copy(_:store:to:)`: the file URL alone cannot be pasted
            // into a text target.
            if written {
                _ = pb.setString(
                    item.fileURLs.map(\.path).joined(separator: "\n"),
                    forType: .string
                )
            }
        default:
            pb.clearContents()
            written = pb.setString(item.text, forType: .string)
        }
        if written, pb === NSPasteboard.general {
            monitor.ignoreNextChange()
        }
        return written
    }

    /// Uses the UTI the bytes were stored under, so a HEIC/JPEG/GIF stays in
    /// its original format instead of being rewritten as PNG. A PNG fallback
    /// is added only when the original is something else and can be decoded.
    private static func preparedImage(
        item: Clip,
        data: Data
    ) -> PreparedImageCopy {
        let format = item.imageFormat ?? ""
        let type = format.isEmpty
            ? NSPasteboard.PasteboardType(UTType.png.identifier)
            : NSPasteboard.PasteboardType(format)
        let fallback: Data? = type == NSPasteboard.PasteboardType(
            UTType.png.identifier
        ) ? nil : pngData(from: data)
        return PreparedImageCopy(data: data, type: type, pngFallback: fallback)
    }

    private static func pngData(from data: Data) -> Data? {
        if let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ),
        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(
            using: .png,
            properties: [:]
        )
    }

    /// Writes plain text produced by a local transform (formats).
    @discardableResult
    func copyText(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        let pb = pasteboard
        if pb === NSPasteboard.general {
            monitor.flushPendingCapture()
        }
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return false }
        if pb === NSPasteboard.general {
            monitor.ignoreNextChange()
        }
        return true
    }
}
