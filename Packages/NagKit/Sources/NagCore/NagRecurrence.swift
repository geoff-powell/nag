import Foundation

extension NagRequest {
    /// Sets the repeat from a recurrence rule, such as the one Siri hears in "every weekday" or "every
    /// Monday and Thursday at 9".
    ///
    /// Daily and weekly rules, every few days or weeks, and monthly rules on one day map onto Nag's repeats.
    /// Particular weekdays or several times a day become custom times. A time in the rule starts the nag
    /// when the request has no start of its own. Nag repeats until the nag is deleted, so the rule's end is
    /// ignored. Throws `.unsupportedRepeat` for the rest, such as yearly or every other month.
    public mutating func setRepeat(_ rule: Calendar.RecurrenceRule, now: Date, calendar: Calendar) throws(NagRequestError) {
        guard rule.months.isEmpty, rule.daysOfTheYear.isEmpty, rule.weeks.isEmpty, rule.setPositions.isEmpty else {
            throw .unsupportedRepeat
        }
        let interval = max(rule.interval, 1)
        let days = try Self.weekdayNumbers(rule.weekdays)
        let clock = rule.hours.flatMap { hour in (rule.minutes.isEmpty ? [0] : rule.minutes).map { hour * 60 + $0 } }
        guard clock.allSatisfy({ (0..<1440).contains($0) }) else { throw .unsupportedRepeat }

        let allDays = Set(1...7)
        let hadStart = startAt != nil
        if !hadStart, !clock.isEmpty {
            let onDays = days.isEmpty ? allDays : days
            startAt = Set(clock)
                .compactMap { NagTime(minute: $0, weekdays: onDays).occurrence(after: now.addingTimeInterval(-60), calendar: calendar) }
                .min()
        }
        let start = startAt ?? now

        switch rule.frequency {
        case .daily, .weekly:
            let weekly = rule.frequency == .weekly
            if days.isEmpty, clock.count <= 1 {
                if interval == 1 {
                    repeatRule = weekly ? .weekly : .daily
                } else {
                    repeatRule = .everyNDays
                    repeatEvery = weekly ? interval * 7 : interval
                }
                return
            }
            guard interval == 1 else { throw .unsupportedRepeat }
            if clock.count <= 1, days == allDays {
                repeatRule = .daily
            } else if clock.count <= 1, days == Set(2...6) {
                repeatRule = .weekdays
            } else if clock.count <= 1, days == [calendar.component(.weekday, from: start)] {
                // Nag's weekly repeat is on the start's weekday.
                repeatRule = .weekly
            } else {
                // "Every day" with no days listed, or "every week" on the start's weekday.
                let onDays = !days.isEmpty ? days : weekly ? [calendar.component(.weekday, from: start)] : allDays
                let parts = calendar.dateComponents([.hour, .minute], from: start)
                let minutes = clock.isEmpty ? [(parts.hour ?? 9) * 60 + (parts.minute ?? 0)] : Set(clock).sorted()
                repeatRule = .custom
                times = minutes.map { NagTime(minute: $0, weekdays: onDays) }
            }
        case .monthly:
            guard interval == 1, days.isEmpty, clock.count <= 1, rule.daysOfTheMonth.count <= 1 else {
                throw .unsupportedRepeat
            }
            let day = rule.daysOfTheMonth.first ?? calendar.component(.day, from: start)
            guard (1...31).contains(day) else { throw .unsupportedRepeat }
            repeatRule = .monthly
            monthDay = day
            if !hadStart, !rule.daysOfTheMonth.isEmpty {
                // "Every month on the 15th" first nags on the next 15th, at the rule's time or 9 AM.
                let anchor = startAt ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
                startAt = RepeatRule.monthly.monthlyOccurrence(
                    after: now.addingTimeInterval(-60),
                    anchor: anchor,
                    monthDay: day,
                    calendar: calendar
                )
            }
        default:
            throw .unsupportedRepeat
        }
    }

    /// Calendar weekday numbers (1 is Sunday) for "every Monday" style days. "The first Monday" can't be
    /// expressed in Nag.
    static func weekdayNumbers(_ weekdays: [Calendar.RecurrenceRule.Weekday]) throws(NagRequestError) -> Set<Int> {
        var numbers = Set<Int>()
        for weekday in weekdays {
            guard case .every(let day) = weekday, let number = day.number else { throw .unsupportedRepeat }
            numbers.insert(number)
        }
        return numbers
    }
}

extension NagTask {
    /// The nag's repeat as a recurrence rule, for Siri and Apple Intelligence. `nil` for a one-off nag, and
    /// for custom times that one rule can't describe.
    public func recurrenceRule(calendar: Calendar) -> Calendar.RecurrenceRule? {
        switch repeatRule {
        case .never:
            return nil
        case .daily:
            return .daily(calendar: calendar)
        case .weekdays:
            return .weekly(calendar: calendar, weekdays: (2...6).compactMap(Locale.Weekday.init(number:)).map { .every($0) })
        case .weekly:
            let weekday = Locale.Weekday(number: calendar.component(.weekday, from: startAt))
            return .weekly(calendar: calendar, weekdays: weekday.map { [.every($0)] } ?? [])
        case .everyNDays:
            return .daily(calendar: calendar, interval: max(repeatEvery, 1))
        case .monthly:
            return .monthly(calendar: calendar, daysOfTheMonth: [monthDay])
        case .custom:
            guard times.count == 1, let time = times.first else { return nil }
            return .weekly(
                calendar: calendar,
                weekdays: time.weekdays.sorted().compactMap(Locale.Weekday.init(number:)).map { .every($0) },
                hours: [time.minute / 60],
                minutes: [time.minute % 60]
            )
        }
    }
}

extension Locale.Weekday {
    private static let ordered: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]

    /// The calendar weekday number, 1 for Sunday to 7 for Saturday.
    var number: Int? {
        Self.ordered.firstIndex(of: self).map { $0 + 1 }
    }

    init?(number: Int) {
        guard (1...7).contains(number) else { return nil }
        self = Self.ordered[number - 1]
    }
}
