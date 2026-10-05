import AppKit
import Foundation

final class ActiveAppTracker {
    static let shared = ActiveAppTracker()

    struct FrontmostSegment: Equatable {
        let bundleID: String?
        let name: String?

        let startedAt: Date
    }

    static let maximumWindow: TimeInterval = 3.0

    private var segments: [FrontmostSegment] = []
    private var observer: NSObjectProtocol?
    private let ownBundleID: String? = Bundle.main.bundleIdentifier

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
