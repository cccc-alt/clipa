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

enum ClipGrouper {
    static func group(
        clips: [Clip],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [ClipSectionModel] {
        guard !clips.isEmpty else { return [] }

        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(
            byAdding: .day, value: -1, to: todayStart
        ) ?? todayStart.addingTimeInterval(-86_400)

        var today: [Clip] = []
        var yesterday: [Clip] = []
        var earlier: [Clip] = []
        for clip in clips {
            let date = clip.lastCopiedAt

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

        if date > now { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .earlier
    }
}
