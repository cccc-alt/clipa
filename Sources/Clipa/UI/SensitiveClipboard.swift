import AppKit

/// Explicit secret-copy actions never enter clipboard history. Cleanup only
/// touches the clipboard version created by this action, not later user copies.
@MainActor
enum SensitiveClipboard {
    @discardableResult
    static func copy(_ value: String, to pasteboard: NSPasteboard = .general,
                     expires: Bool = true) -> Bool {
        let general = pasteboard.name == NSPasteboard.general.name
        if general { ClipboardMonitor.shared.flushPendingCapture() }
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        let written = pasteboard.writeObjects([item])
        if general { ClipboardMonitor.shared.ignoreNextChange() }
        let version = pasteboard.changeCount
        if written && expires {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                guard pasteboard.changeCount == version else { return }
                pasteboard.clearContents()
                if general { ClipboardMonitor.shared.ignoreNextChange() }
            }
        }
        return written
    }
}
