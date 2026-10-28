import Foundation

extension Escalation {
    private var stepLength: TimeInterval? {
        switch self {
        case .steady: nil
        case .gentle: 3600
        case .relentless: 1800
        }
    }

    private var factor: Double {
        switch self {
        case .steady: 1
        case .gentle: 0.75
        case .relentless: 0.5
        }
    }

    private func floor(for base: TimeInterval) -> TimeInterval {
        switch self {
        case .steady: base
        case .gentle: base / 2
        case .relentless: 60
        }
    }

    /// Seconds between nags once a nag has been overdue for `overdue` seconds. Never under a minute,
    /// which is also the shortest repeating notification iOS allows.
    public func interval(base: TimeInterval, overdue: TimeInterval) -> TimeInterval {
        let base = max(60, base)
        guard let stepLength else { return base }
        let steps = (max(0, overdue) / stepLength).rounded(.down)
        return max(60, floor(for: base), base * pow(factor, steps))
    }

    /// The overdue duration at which the interval next tightens, if it still will.
    public func nextTightening(base: TimeInterval, overdue: TimeInterval) -> TimeInterval? {
        guard let stepLength else { return nil }
        let boundary = ((max(0, overdue) / stepLength).rounded(.down) + 1) * stepLength
        return interval(base: base, overdue: boundary) < interval(base: base, overdue: overdue) ? boundary : nil
    }
}

extension QuietHours {
    public var isActive: Bool { enabled && startMinute != endMinute }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard isActive else { return false }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return startMinute < endMinute
            ? (startMinute..<endMinute).contains(minute)
            : minute >= startMinute || minute < endMinute
    }

    /// `date`, or the moment quiet hours end if `date` falls inside them.
    public func nextAllowed(after date: Date, calendar: Calendar) -> Date {
        guard contains(date, calendar: calendar),
              let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 0, of: date)
        else { return date }
        return end > date ? end : calendar.date(byAdding: .day, value: 1, to: end) ?? date
    }
}

/// A notification the platform layer should have pending.
public struct PlannedNotification: Hashable, Sendable {
    public enum Trigger: Hashable, Sendable {
        case at(Date)
        /// Repeats forever until removed. Keeps nagging even if the app never runs again.
        case every(seconds: Int)
    }

    /// Encodes everything that matters, so unchanged notifications keep their identifier and aren't
    /// rescheduled (rescheduling a repeating trigger restarts its clock).
    public var identifier: String
    public var taskID: UUID
    public var trigger: Trigger
    public var title: String
    public var body: String
    public var category: String
    public var timeSensitive: Bool
}

public struct NagPlan: Hashable, Sendable {
    public var notifications: [PlannedNotification]
    /// The next moment the plan changes shape: a nag starts, a snooze ends, escalation steps up, quiet
    /// hours end. iOS schedules a DeviceActivity wake-up here so the extension can re-plan.
    public var nextWake: Date?
    /// Nags whose current occurrence has started and isn't done (badge count).
    public var outstandingCount: Int
}

/// Turns nags into notifications.
///
/// Nags that are already due get one repeating notification each, which keeps firing with no help from
/// the app. Nags that start later get one-off notifications along their escalation curve, earliest
/// first, within iOS's limit of 64 pending notifications per app.
public struct NagPlanner: Sendable {
    public var maxPending: Int
    public var horizon: TimeInterval
    /// Repeating notifications can't respect quiet hours by themselves. Without a background wake-up to
    /// remove them at night, plan only one-off notifications.
    public var allowRepeating: Bool
    public var calendar: Calendar

    public init(maxPending: Int = 60, horizon: TimeInterval = 48 * 3600, allowRepeating: Bool = true, calendar: Calendar = .current) {
        self.maxPending = maxPending
        self.horizon = horizon
        self.allowRepeating = allowRepeating
        self.calendar = calendar
    }

    public func plan(tasks: [NagTask], quietHours: QuietHours, now: Date) -> NagPlan {
        var repeating: [PlannedNotification] = []
        var oneOffs: [(date: Date, notification: PlannedNotification)] = []
        var wake: Date?
        func considerWake(_ date: Date) {
            if date > now, date < (wake ?? .distantFuture) { wake = date }
        }

        let quietNow = quietHours.contains(now, calendar: calendar)
        let until = now.addingTimeInterval(horizon)

        for task in tasks {
            guard let start = task.nagStart else { continue }
            let base = TimeInterval(max(1, task.style.intervalMinutes) * 60)
            let category = NagID.Category.forTask(task, canSnooze: (task.snoozesLeft ?? 1) > 0)
            let contentKey = StableHash.hex("\(task.title)|\(task.notes)|\(category)|\(task.style.breakThroughFocus)")
            let prefix = "\(NagID.nagNotificationPrefix)\(task.id.uuidString)|"

            if start <= now, allowRepeating, !quietNow {
                let overdue = now.timeIntervalSince(task.startAt)
                let seconds = Int(task.style.escalation.interval(base: base, overdue: overdue).rounded())
                let tier = NagMessages.tier(overdue: overdue)
                repeating.append(PlannedNotification(
                    identifier: "\(prefix)every|\(seconds)|\(tier)|\(contentKey)",
                    taskID: task.id,
                    trigger: .every(seconds: seconds),
                    title: task.title,
                    body: NagMessages.repeatingBody(title: task.title, tier: tier),
                    category: category,
                    timeSensitive: task.style.breakThroughFocus
                ))
                if let tightening = task.style.escalation.nextTightening(base: base, overdue: overdue) {
                    considerWake(task.startAt.addingTimeInterval(tightening))
                }
                if let tierChange = NagMessages.nextTierChange(overdue: overdue) {
                    considerWake(task.startAt.addingTimeInterval(tierChange))
                }
                continue
            }

            considerWake(start)
            for (date, number) in fireDates(for: task, from: start, base: base, quietHours: quietHours, now: now, until: until) {
                let overdue = date.timeIntervalSince(task.startAt)
                oneOffs.append((date, PlannedNotification(
                    identifier: "\(prefix)\(Int(date.timeIntervalSince1970))|\(contentKey)",
                    taskID: task.id,
                    trigger: .at(date),
                    title: task.title,
                    body: NagMessages.body(title: task.title, notes: task.notes, number: number, overdue: overdue),
                    category: category,
                    timeSensitive: task.style.breakThroughFocus
                )))
            }
        }

        if quietNow, tasks.contains(where: { $0.isNagging(at: now) }) {
            considerWake(quietHours.nextAllowed(after: now, calendar: calendar))
        }

        oneOffs.sort { $0.date < $1.date }
        let budget = max(0, maxPending - repeating.count)
        return NagPlan(
            notifications: repeating + oneOffs.prefix(budget).map(\.notification),
            nextWake: wake,
            outstandingCount: tasks.filter { $0.isOutstanding(at: now) }.count
        )
    }

    /// Fire dates after `now`, following the escalation curve from `start`. Anchored on `start` rather than
    /// `now` so re-planning produces the same dates (and identifiers) instead of pushing nags back.
    func fireDates(
        for task: NagTask,
        from start: Date,
        base: TimeInterval,
        quietHours: QuietHours,
        now: Date,
        until: Date
    ) -> [(date: Date, number: Int)] {
        var result: [(date: Date, number: Int)] = []
        var next = start
        var number = 0
        var iterations = 0
        while next <= until, result.count < maxPending, iterations < 20_000 {
            iterations += 1
            let fire = quietHours.nextAllowed(after: next, calendar: calendar)
            number += 1
            if fire > now, fire <= until, result.last?.date != fire {
                result.append((fire, number))
            }
            let overdue = fire.timeIntervalSince(task.startAt)
            next = fire.addingTimeInterval(task.style.escalation.interval(base: base, overdue: overdue))
        }
        return result
    }
}

/// Nag copy that gets pushier the longer something is ignored. Varied on purpose: the same words every
/// time are easy to tune out.
public enum NagMessages {
    static let tierStarts: [TimeInterval] = [0, 15 * 60, 60 * 60, 3 * 60 * 60]

    public static func tier(overdue: TimeInterval) -> Int {
        tierStarts.lastIndex { overdue >= $0 } ?? 0
    }

    static func nextTierChange(overdue: TimeInterval) -> TimeInterval? {
        tierStarts.first { $0 > overdue }
    }

    public static func body(title: String, notes: String, number: Int, overdue: TimeInterval) -> String {
        if number <= 1 {
            return notes.isEmpty ? "It's time. Start with the smallest step." : notes
        }
        let late = NagFormat.duration(overdue)
        let lines: [String]
        switch tier(overdue: overdue) {
        case 0:
            lines = [
                "Nag #\(number). Now's a good moment.",
                "Hey. This is still waiting for you.",
                "Quick one: just start it.",
            ]
        case 1:
            lines = [
                "Still not done, \(late) later. Two minutes is enough to start.",
                "Nag #\(number). You said you'd do this.",
                "Overdue by \(late). Do the first tiny step.",
            ]
        case 2:
            lines = [
                "Nag #\(number). Seriously, \(late) overdue.",
                "This takes less time than ignoring me.",
                "Future you is asking. \(late) overdue.",
            ]
        default:
            lines = [
                "Nag #\(number). I'm not going to stop.",
                "\(late) overdue. Still here. Still nagging.",
                "Do it now and I'll go quiet.",
            ]
        }
        return lines[number % lines.count]
    }

    public static func repeatingBody(title: String, tier: Int) -> String {
        switch tier {
        case 0: "It's time. Start with the smallest step."
        case 1: "Still not done. Two minutes is enough to start."
        case 2: "Overdue. This takes less time than ignoring me."
        default: "I'm not going to stop until this is done."
        }
    }
}
