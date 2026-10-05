import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ClipboardWriter {
    static let shared = ClipboardWriter()

    private struct PreparedImageCopy: Sendable {
        let data: Data
        let type: NSPasteboard.PasteboardType
        let pngFallback: Data?
    }

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

            if let png = prepared.pngFallback {
                _ = pb.setData(png, forType: .png)
            }
        case .file:
            guard !item.fileURLs.isEmpty else { return false }
            pb.clearContents()
            written = pb.writeObjects(item.fileURLs as [NSURL])

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

    @MainActor
    func copyAsync(
        _ item: Clip,
        store: ClipStore = .shared,
        to pasteboard: NSPasteboard = .general
    ) async -> Bool {

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

            guard let data = await store.imageDataAsync(for: item) else {
                return false
            }
            let prepared = await Task.detached(
                priority: .userInitiated
            ) { () -> PreparedImageCopy in
                Self.preparedImage(item: item, data: data)
            }.value

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
