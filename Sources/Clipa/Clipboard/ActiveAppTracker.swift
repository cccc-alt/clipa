import AppKit
import Foundation

/// Which application was frontmost over the recent past.
///
/// macOS never tells an app who wrote to the pasteboard, so Clipa attributes a
/// capture to the app that was frontmost when the change appeared. The
/// pasteboard is polled rather than observed, so that moment is only known to
/// lie *somewhere* inside the last poll window. Keeping a short timeline lets
/// the capture path evaluate every app that could have owned the change instead
/// of trusting one sample taken up to a poll interval too late.
///
/// It also answers "which app did the user mean" when Clipa itself is frontmost
/// (floating panel, settings window).
///
/// Main-thread only: it reads `NSWorkspace` state and feeds the capture path,
/// which is main-thread too.
final class ActiveAppTracker {
    static let shared = ActiveAppTracker()

    struct FrontmostSegment: Equatable {
        let bundleID: String?
        let name: String?
        /// When this app became frontmost. Repeats of the same app do not
        /// extend the segment, so this is the start of the stretch.
        let startedAt: Date
    }

    /// Longest window a caller may ask about. The pasteboard poll interval is
    /// far below this, so the whole poll window can always be reconstructed.
    static let maximumWindow: TimeInterval = 3.0

    private var segments: [FrontmostSegment] = []
    private var observer: NSObjectProtocol?
    private let ownBundleID: String? = Bundle.main.bundleIdentifier

    /// The most recent app that was frontmost and is not Clipa itself.
    private(set) var lastExternalApp: NSRunningApplication?

    private init() {}

    func start() {
        guard observer == nil else { return }
        record(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.record(app)
        }
    }

    func stop() {
        guard let observer else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    /// Appends a frontmost segment. Recording the app that is already current
    /// is a no-op so the timeline keeps segment *starts*, which is what the
    /// window math needs.
    func record(_ app: NSRunningApplication?, at date: Date = Date()) {
        guard let app else { return }
        if app.bundleIdentifier != ownBundleID {
            lastExternalApp = app
        }
        record(
            bundleID: app.bundleIdentifier,
            name: app.localizedName,
            at: date
        )
    }

    /// Test seam: the timeline only depends on the identity of the app, not on
    /// a live `NSRunningApplication`.
    func record(bundleID: String?, name: String?, at date: Date = Date()) {
        prune(before: date)
        if let last = segments.last, last.bundleID == bundleID {
            return
        }
        segments.append(
            FrontmostSegment(
                bundleID: bundleID,
                name: name,
                startedAt: date
            )
        )
    }

    /// Every app that was frontmost at any moment in `(since, now]`, oldest
    /// first and deduplicated by bundle id. The app that was already frontmost
    /// when the window opened is included, because the change may have
    /// happened before the user switched away from it.
    func frontmostSince(
        _ since: Date,
        now: Date = Date()
    ) -> [FrontmostSegment] {
        prune(before: now)
        guard !segments.isEmpty else { return [] }

        var coveringIndex: Int?
        for (index, segment) in segments.enumerated() {
            if segment.startedAt <= since {
                coveringIndex = index
            } else {
                break
            }
        }

        var window: [FrontmostSegment] = []
        if let coveringIndex {
            window.append(segments[coveringIndex])
            window.append(contentsOf: segments[(coveringIndex + 1)...])
        } else {
            window = segments
        }

        var seen = Set<String?>()
        return window.filter { seen.insert($0.bundleID).inserted }
    }

    /// Drops segments older than the retention window, keeping the one that
    /// covers the cutoff so a window start is never silently lost.
    private func prune(before date: Date) {
        let cutoff = date.addingTimeInterval(-Self.maximumWindow)
        var dropCount = 0
        for (index, segment) in segments.enumerated() {
            if segment.startedAt < cutoff {
                dropCount = index
            } else {
                break
            }
        }
        if dropCount > 0 {
            segments.removeFirst(dropCount)
        }
    }
}
