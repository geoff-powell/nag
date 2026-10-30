import Foundation

public enum NagUndo {
    public static let window: TimeInterval = 10 * 60
    public static let toastDuration: TimeInterval = 5
}

extension RepeatRule {
    func includes(weekday: Int, anchorWeekday: Int) -> Bool {
        switch self {
        case .never, .custom: false
        case .daily: true
        case .weekdays: (2...6).contains(weekday)
        case .weekly: weekday == anchorWeekday
        }
    }

    /// The first occurrence strictly after `date`, at `anchor`'s time of day (and weekday, for weekly).
    /// `.custom` occurrences come from the nag's times instead; see `NagTask.occurrence(after:calendar:)`.
    public func occurrence(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
        guard self != .never, self != .custom else { return nil }
        let hour = calendar.component(.hour, from: anchor)
        let minute = calendar.component(.minute, from: anchor)
        let anchorWeekday = calendar.component(.weekday, from: anchor)
        var day = calendar.startOfDay(for: date)
        for _ in 0..<15 {
            if includes(weekday: calendar.component(.weekday, from: day), anchorWeekday: anchorWeekday),
               let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
               candidate > date {
                return candidate
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }
}

extension NagTime {
    public var isValid: Bool { !weekdays.isEmpty && (0..<1440).contains(minute) }

    /// The first time strictly after `date` on one of `weekdays`.
    public func occurrence(after date: Date, calendar: Calendar) -> Date? {
        guard isValid else { return nil }
        var day = calendar.startOfDay(for: date)
        for _ in 0..<9 {
            if weekdays.contains(calendar.component(.weekday, from: day)),
               let candidate = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day),
               candidate > date {
                return candidate
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }
}

extension Calendar {
    /// Midnight at the end of `date`'s day.
    public func endOfDay(for date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }
}

extension NagTask {
    public var isRepeating: Bool { repeatRule != .never }

    /// A fresh copy with the same settings and schedule, but none of this nag's progress. The copy keeps
    /// the source and link but not the external ID, so the source can't update it.
    public func duplicate(now: Date) -> NagTask {
        NagTask(
            title: "\(title) copy",
            notes: notes,
            startAt: startAt,
            repeatRule: repeatRule,
            times: times.map { NagTime(minute: $0.minute, weekdays: $0.weekdays) },
            style: style,
            proof: proof,
            source: source,
            link: link,
            now: now
        )
    }

    /// A custom-schedule nag needs at least one time, and every time needs at least one day.
    public var hasValidSchedule: Bool {
        repeatRule != .custom || (!times.isEmpty && times.allSatisfy(\.isValid))
    }

    /// The next occurrence strictly after `date`.
    public func occurrence(after date: Date, calendar: Calendar) -> Date? {
        if repeatRule == .custom {
            return times.compactMap { $0.occurrence(after: date, calendar: calendar) }.min()
        }
        return repeatRule.occurrence(after: date, anchor: startAt, calendar: calendar)
    }

    /// Custom-schedule nags take their start from their times. When the schedule is new or has
    /// changed since `previous`, moves `startAt` to the next scheduled time after `now`.
    public mutating func alignStartToSchedule(previous: NagTask?, now: Date, calendar: Calendar) {
        guard repeatRule == .custom, hasValidSchedule else { return }
        if let previous, previous.repeatRule == .custom, previous.times == times { return }
        if let next = occurrence(after: now, calendar: calendar), next != startAt {
            startAt = next
            startedAt = nil
        }
    }

    /// A one-off nag that's done. Repeating nags are never finished; they move on to the next occurrence.
    public var isFinished: Bool { !isRepeating && completedAt != nil }

    /// When nagging starts, or resumes after a snooze, for the current occurrence.
    public var nagStart: Date? {
        guard !isFinished else { return nil }
        let base = max(startAt, snoozedUntil ?? .distantPast)
        if let workEnd = workingUntil(), workEnd > base { return workEnd }
        return base
    }

    /// The current occurrence has started and isn't done. Snoozed nags are still outstanding.
    public func isOutstanding(at now: Date) -> Bool {
        !isFinished && startAt <= now
    }

    /// Nag notifications should be going off right now.
    public func isNagging(at now: Date) -> Bool {
        guard let nagStart else { return false }
        return nagStart <= now
    }

    public func isSnoozed(at now: Date) -> Bool {
        guard isOutstanding(at: now), let snoozedUntil else { return false }
        return snoozedUntil > now
    }

    public func isStarted(at now: Date) -> Bool {
        guard !isFinished, let startedAt else { return false }
        return startedAt >= startAt
    }

    public func workingUntil() -> Date? {
        guard let startedAt, startedAt >= startAt else { return nil }
        return startedAt.addingTimeInterval(TimeInterval(style.workMinutes * 60))
    }

    public func isWorking(at now: Date) -> Bool {
        guard isStarted(at: now), let workingUntil = workingUntil() else { return false }
        return now < workingUntil
    }

    public mutating func start(at now: Date) {
        guard isOutstanding(at: now), !isStarted(at: now) else { return }
        startedAt = now
        updatedAt = now
    }

    /// Counts toward an unlock. One-off nags must be done; repeating nags must have nothing left today.
    public func isSatisfied(at now: Date, calendar: Calendar) -> Bool {
        isRepeating ? startAt >= calendar.endOfDay(for: now) : completedAt != nil
    }

    /// Done is available: one-off nags until finished, repeating nags for today's or an overdue occurrence.
    public func canComplete(at now: Date, calendar: Calendar) -> Bool {
        isRepeating ? startAt < calendar.endOfDay(for: now) : completedAt == nil
    }

    public var snoozesLeft: Int? {
        style.maxSnoozes.map { max(0, $0 - snoozeCount) }
    }

    public func canSnooze(at now: Date) -> Bool {
        isOutstanding(at: now) && (snoozesLeft ?? 1) > 0
    }

    public mutating func complete(at now: Date, calendar: Calendar) {
        let undo = CompletionUndo(
            startAt: startAt,
            snoozedUntil: snoozedUntil,
            snoozeCount: snoozeCount,
            lastCompletedAt: lastCompletedAt,
            completedAt: completedAt,
            startedAt: startedAt,
            completedAtMoment: now
        )
        lastCompletedAt = now
        snoozedUntil = nil
        snoozeCount = 0
        startedAt = nil
        updatedAt = now
        if isRepeating {
            // Finishing early completes the upcoming occurrence; finishing late skips any missed ones.
            let base = max(now, startAt)
            startAt = occurrence(after: base, calendar: calendar)
                ?? base.addingTimeInterval(86_400)
        } else {
            completedAt = now
        }
        completionUndo = undo
    }

    public func canUndoCompletion(at now: Date) -> Bool {
        guard let completionUndo else { return false }
        let elapsed = now.timeIntervalSince(completionUndo.completedAtMoment)
        return elapsed > -60 && elapsed < NagUndo.window
    }

    @discardableResult
    public mutating func undoCompletion(at now: Date) -> Bool {
        guard let undo = completionUndo, canUndoCompletion(at: now) else { return false }
        startAt = undo.startAt
        snoozedUntil = undo.snoozedUntil
        snoozeCount = undo.snoozeCount
        lastCompletedAt = undo.lastCompletedAt
        completedAt = undo.completedAt
        startedAt = undo.startedAt
        undoneCompletionAt = undo.completedAtMoment
        updatedAt = now
        completionUndo = nil
        return true
    }

    public mutating func reopen(at now: Date) {
        completedAt = nil
        updatedAt = now
    }

    @discardableResult
    public mutating func snooze(at now: Date) -> Bool {
        snooze(at: now, minutes: style.snoozeMinutes)
    }

    @discardableResult
    public mutating func snooze(at now: Date, minutes: Int) -> Bool {
        guard canSnooze(at: now) else { return false }
        snoozedUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
        snoozeCount += 1
        updatedAt = now
        return true
    }
}
