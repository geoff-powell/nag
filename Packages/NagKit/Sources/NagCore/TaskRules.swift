import Foundation

extension RepeatRule {
    func includes(weekday: Int, anchorWeekday: Int) -> Bool {
        switch self {
        case .never: false
        case .daily: true
        case .weekdays: (2...6).contains(weekday)
        case .weekly: weekday == anchorWeekday
        }
    }

    /// The first occurrence strictly after `date`, at `anchor`'s time of day (and weekday, for weekly).
    public func occurrence(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
        guard self != .never else { return nil }
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

extension Calendar {
    /// Midnight at the end of `date`'s day.
    public func endOfDay(for date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }
}

extension NagTask {
    public var isRepeating: Bool { repeatRule != .never }

    /// A one-off nag that's done. Repeating nags are never finished; they move on to the next occurrence.
    public var isFinished: Bool { !isRepeating && completedAt != nil }

    /// When nagging starts, or resumes after a snooze, for the current occurrence.
    public var nagStart: Date? {
        guard !isFinished else { return nil }
        if let snoozedUntil, snoozedUntil > startAt { return snoozedUntil }
        return startAt
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
        lastCompletedAt = now
        snoozedUntil = nil
        snoozeCount = 0
        updatedAt = now
        if isRepeating {
            // Finishing early completes the upcoming occurrence; finishing late skips any missed ones.
            let base = max(now, startAt)
            startAt = repeatRule.occurrence(after: base, anchor: startAt, calendar: calendar)
                ?? base.addingTimeInterval(86_400)
        } else {
            completedAt = now
        }
    }

    public mutating func reopen(at now: Date) {
        completedAt = nil
        updatedAt = now
    }

    @discardableResult
    public mutating func snooze(at now: Date) -> Bool {
        guard canSnooze(at: now) else { return false }
        snoozedUntil = now.addingTimeInterval(TimeInterval(style.snoozeMinutes * 60))
        snoozeCount += 1
        updatedAt = now
        return true
    }
}
