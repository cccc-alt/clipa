import Foundation

enum ClipSection: Int, CaseIterable {
    case today
    case yesterday
    case earlier

    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .earlier: return "更早"
        }
    }
}

struct ClipSectionModel: Identifiable, Equatable {
    let section: ClipSection
    let clips: [Clip]

    var id: String { section.title }
    var title: String { section.title }
}

/// Sectioning is UI-shaped but UI-independent: the popup never computes date
/// buckets itself. Recency uses `lastCopiedAt`, matching the store ordering.
enum ClipGrouper {
    static func group(
        clips: [Clip],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [ClipSectionModel] {
        guard !clips.isEmpty else { return [] }

        // One pass, and no `Calendar` call per clip.
        //
        // This used to filter the whole array once per section, calling
        // `bucket(...)` for every clip every time — on a 1000-row result that
        // is ~3000 Calendar lookups on the main actor, ~50 ms of the typing
        // stall. The three day boundaries do not depend on the clip, so they
        // are resolved once here.
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(
            byAdding: .day, value: -1, to: todayStart
        ) ?? todayStart.addingTimeInterval(-86_400)

        var today: [Clip] = []
        var yesterday: [Clip] = []
        var earlier: [Clip] = []
        for clip in clips {
            let date = clip.lastCopiedAt
            // `date >= todayStart` rather than a window that also checks
            // `date < tomorrowStart`: a timestamp in the future — a clock that
            // moved backwards, a row restored from another machine — used to
            // fall through to 更早 and appear *below* yesterday, even though the
            // user had just watched it arrive.
            if date >= todayStart {
                today.append(clip)
            } else if date >= yesterdayStart {
                yesterday.append(clip)
            } else {
                earlier.append(clip)
            }
        }

        var models: [ClipSectionModel] = []
        for (section, bucket) in [
            (ClipSection.today, today),
            (ClipSection.yesterday, yesterday),
            (ClipSection.earlier, earlier)
        ] where !bucket.isEmpty {
            models.append(ClipSectionModel(section: section, clips: bucket))
        }
        return models
    }

    static func bucket(
        for date: Date,
        calendar: Calendar,
        now: Date = Date()
    ) -> ClipSection {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        // Kept in step with `group(...)`: a future timestamp is "today", not
        // "earlier".
        if date > now { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .earlier
    }
}
