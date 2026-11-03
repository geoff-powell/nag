import Foundation

/// A look back at one week: what got done, how long things took to get going, and one gentle idea for
/// a nag that keeps running late. It describes; it never scores, and it never counts what was missed.
public struct WeeklyReview: Hashable, Sendable {
    /// One nag's week.
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var count: Int
        /// Average time from due to started (or done).
        public var averageStartDelay: TimeInterval
        public var snoozes: Int
        public var keyScans: Int

        public init(id: UUID, title: String, count: Int, averageStartDelay: TimeInterval, snoozes: Int, keyScans: Int) {
            self.id = id
            self.title = title
            self.count = count
            self.averageStartDelay = averageStartDelay
            self.snoozes = snoozes
            self.keyScans = keyScans
        }
    }

    /// Moving a nag to when it usually gets done anyway.
    public struct Suggestion: Hashable, Sendable {
        public var nagID: UUID
        public var title: String
        /// When the nag is due now, in minutes after midnight.
        public var currentMinute: Int
        /// The suggested time, in minutes after midnight.
        public var suggestedMinute: Int
        /// The median time from due to started over the weeks looked at.
        public var typicalDelay: TimeInterval
        public var samples: Int

        public init(nagID: UUID, title: String, currentMinute: Int, suggestedMinute: Int, typicalDelay: TimeInterval, samples: Int) {
            self.nagID = nagID
            self.title = title
            self.currentMinute = currentMinute
            self.suggestedMinute = suggestedMinute
            self.typicalDelay = typicalDelay
            self.samples = samples
        }

        /// The suggestion in words. `formatTime` turns minutes after midnight into a time of day.
        public func message(formatTime: (Int) -> String) -> String {
            let minutes = Int((typicalDelay / 60).rounded())
            return "“\(title)” usually gets going about \(minutes) min after \(formatTime(currentMinute)). "
                + "Moving it to \(formatTime(suggestedMinute)) might suit your day better."
        }
    }

    /// An average start this late puts a nag in `slipping`.
    public static let slipThreshold: TimeInterval = 15 * 60
    public static let slippingLimit = 3
    /// How many weeks, ending with the reviewed one, a suggestion looks at.
    public static let suggestionWeeks = 4
    public static let suggestionMinimumSamples = 3
    /// A typical delay outside this range isn't a matter of the nag's time.
    public static let suggestionDelays: ClosedRange<TimeInterval> = (20 * 60)...(4 * 3600)
    /// Suggested times are rounded to this many minutes.
    public static let suggestionStep = 15

    public var week: DateInterval
    public var doneCount: Int
    /// Average time from due to started (or done) across everything done this week.
    public var averageStartDelay: TimeInterval?
    /// Most done first.
    public var entries: [Entry]
    /// Nags that usually got going late, latest first.
    public var slipping: [Entry]
    public var suggestion: Suggestion?
    public var streak: ProgressStreak

    public var isEmpty: Bool { doneCount == 0 }

    /// Reviews the week containing `date`. `tasks` are the current nags: suggestions are only made for
    /// repeating nags that still exist and are still due at the time the suggestion would move.
    public static func make(
        history: CompletionHistory,
        tasks: [NagTask],
        week date: Date,
        now: Date,
        calendar: Calendar
    ) -> WeeklyReview {
        let week = calendar.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86_400)

        var totals: [UUID: (title: String, latest: Date, count: Int, delay: TimeInterval, snoozes: Int, keyScans: Int)] = [:]
        func add(_ id: UUID, title: String, at date: Date, count: Int, delay: TimeInterval, snoozes: Int, keyScans: Int) {
            var total = totals[id] ?? (title, date, 0, 0, 0, 0)
            if date >= total.latest { total.title = title; total.latest = date }
            total.count += count
            total.delay += delay
            total.snoozes += snoozes
            total.keyScans += keyScans
            totals[id] = total
        }
        for record in history.records where week.containsHalfOpen(record.completedAt) {
            add(record.nagID, title: record.title, at: record.completedAt, count: 1, delay: record.startDelay,
                snoozes: record.snoozes, keyScans: record.keyScanned ? 1 : 0)
        }
        for rollup in history.rollups where week.containsHalfOpen(rollup.midweek) {
            add(rollup.nagID, title: rollup.title, at: rollup.weekStart, count: rollup.count, delay: rollup.totalStartDelay,
                snoozes: rollup.snoozes, keyScans: rollup.keyScans)
        }

        let entries = totals
            .filter { $0.value.count > 0 }
            .map { id, total in
                Entry(id: id, title: total.title, count: total.count, averageStartDelay: total.delay / Double(total.count),
                      snoozes: total.snoozes, keyScans: total.keyScans)
            }
            .sorted { ($1.count, $0.title.lowercased(), $0.id.uuidString) < ($0.count, $1.title.lowercased(), $1.id.uuidString) }
        let doneCount = entries.reduce(0) { $0 + $1.count }
        let totalDelay = totals.values.reduce(0) { $0 + $1.delay }
        let slipping = entries
            .filter { $0.averageStartDelay >= slipThreshold }
            .sorted { ($1.averageStartDelay, $0.id.uuidString) < ($0.averageStartDelay, $1.id.uuidString) }
            .prefix(slippingLimit)

        return WeeklyReview(
            week: week,
            doneCount: doneCount,
            averageStartDelay: doneCount > 0 ? totalDelay / Double(doneCount) : nil,
            entries: entries,
            slipping: Array(slipping),
            suggestion: suggestion(history: history, tasks: tasks, week: week, calendar: calendar),
            streak: ProgressStreak.make(history: history, now: now, calendar: calendar)
        )
    }

    /// The nag that most consistently gets going late, if moving it would help. Looks at the reviewed week
    /// and the few before it, so a nag needs a handful of completions at the same time of day.
    static func suggestion(history: CompletionHistory, tasks: [NagTask], week: DateInterval, calendar: Calendar) -> Suggestion? {
        let start = calendar.date(byAdding: .weekOfYear, value: -(suggestionWeeks - 1), to: week.start) ?? week.start
        let window = DateInterval(start: start, end: week.end)
        let recent = history.records.filter { window.containsHalfOpen($0.completedAt) }
        let byNag = Dictionary(grouping: recent, by: \.nagID)

        var best: Suggestion?
        for task in tasks where task.isRepeating {
            guard let records = byNag[task.id] else { continue }
            // Nags with several times a day: look at the time that comes up most.
            let byMinute = Dictionary(grouping: records) { minuteOfDay($0.scheduledAt, calendar: calendar) }
            guard let common = byMinute.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) else { continue }
            let (minute, samples) = (common.key, common.value)
            guard samples.count >= suggestionMinimumSamples,
                  isScheduled(task, at: minute, calendar: calendar)
            else { continue }
            let delay = median(samples.map(\.startDelay))
            guard suggestionDelays.contains(delay) else { continue }
            let step = Double(suggestionStep * 60)
            let shift = Int((delay / step).rounded()) * suggestionStep
            let suggested = ((minute + shift) % 1440 + 1440) % 1440
            let candidate = Suggestion(
                nagID: task.id,
                title: task.title,
                currentMinute: minute,
                suggestedMinute: suggested,
                typicalDelay: delay,
                samples: samples.count
            )
            if let current = best, (current.typicalDelay, current.nagID.uuidString) >= (delay, task.id.uuidString) { continue }
            best = candidate
        }
        return best
    }

    /// Whether the nag is still due at `minute`, so a suggestion isn't made for a time already changed.
    static func isScheduled(_ task: NagTask, at minute: Int, calendar: Calendar) -> Bool {
        task.repeatRule == .custom
            ? task.times.contains { $0.minute == minute }
            : minuteOfDay(task.startAt, calendar: calendar) == minute
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Start of the earliest week with anything in the history, for paging back through reviews.
    public static func earliestWeek(in history: CompletionHistory, calendar: Calendar) -> Date? {
        let dates = history.records.map(\.completedAt) + history.rollups.map(\.midweek)
        return dates.min().flatMap { calendar.dateInterval(of: .weekOfYear, for: $0)?.start }
    }
}

/// Weeks with at least one thing done. A week with nothing done pauses the count: it doesn't grow, but
/// it never goes back to zero, and quiet weeks are never counted or shown.
public struct ProgressStreak: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// Nothing done yet, ever.
        case notStarted
        /// Something got done this week.
        case active
        /// Nothing yet this week, but last week counted. There's still time.
        case open
        /// Nothing this week or last. Picks up again with the next thing done.
        case paused
    }

    public var weeks: Int
    public var status: Status

    public init(weeks: Int, status: Status) {
        self.weeks = weeks
        self.status = status
    }

    public static func make(history: CompletionHistory, now: Date, calendar: Calendar) -> ProgressStreak {
        func weekStart(_ date: Date) -> Date? { calendar.dateInterval(of: .weekOfYear, for: date)?.start }
        guard let thisWeek = weekStart(now) else { return ProgressStreak(weeks: 0, status: .notStarted) }
        let dates = history.records.map(\.completedAt) + history.rollups.filter { $0.count > 0 }.map(\.midweek)
        let weeks = Set(dates.compactMap(weekStart)).filter { $0 <= thisWeek }
        guard !weeks.isEmpty else { return ProgressStreak(weeks: 0, status: .notStarted) }
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek).flatMap(weekStart)
        let status: Status = weeks.contains(thisWeek)
            ? .active
            : lastWeek.map(weeks.contains) == true ? .open : .paused
        return ProgressStreak(weeks: weeks.count, status: status)
    }
}

extension DateInterval {
    /// `contains` includes the end; weeks share their boundary with the next one.
    func containsHalfOpen(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

/// Wording for the weekly review, shared by the iPhone and Mac apps. Describes; never scores.
public enum ReviewCopy {
    /// "about 25 min", or "right on time" for under a minute.
    public static func delay(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        guard minutes >= 1 else { return "right on time" }
        guard minutes >= 60 else { return "about \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "about \(hours) hr" : "about \(hours) hr \(rest) min"
    }

    public static func streak(_ streak: ProgressStreak) -> String? {
        let weeks = streak.weeks == 1 ? "1 week" : "\(streak.weeks) weeks"
        switch streak.status {
        case .notStarted: return nil
        case .active: return "\(weeks) with progress, this one included."
        case .open: return "\(weeks) with progress. Anything you finish this week adds another."
        case .paused: return "\(weeks) with progress. Paused for now; it picks up with the next thing you finish."
        }
    }

    /// "This week", "Last week", or the week's dates.
    public static func weekTitle(_ week: DateInterval, now: Date, calendar: Calendar) -> String {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) else { return "" }
        if week.start == thisWeek.start { return "This week" }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start), week.start == lastWeek {
            return "Last week"
        }
        let lastDay = week.end.addingTimeInterval(-1)
        var style = Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .current
        return style.format(week.start..<lastDay)
    }
}
