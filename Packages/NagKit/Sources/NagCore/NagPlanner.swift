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

    public func plan(
        tasks: [NagTask],
        quietHours: QuietHours,
        tone: NagTone = .standard,
        now: Date
    ) -> NagPlan {
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
            let effectiveTone = task.style.tone ?? tone
            let base = TimeInterval(max(1, task.style.intervalMinutes) * 60)
            let checkIn = task.isStarted(at: now)
            if checkIn, let workingUntil = task.workingUntil() { considerWake(workingUntil) }
            let category = NagID.Category.forTask(task, canSnooze: (task.snoozesLeft ?? 1) > 0)
            let contentKey = StableHash.hex(
                "\(task.title)|\(task.notes)|\(category)|\(task.style.breakThroughFocus)|\(effectiveTone.rawValue)|\(checkIn)"
            )
            let prefix = "\(NagID.nagNotificationPrefix)\(task.id.uuidString)|"

            if start <= now, allowRepeating, !quietNow {
                let overdue = now.timeIntervalSince(task.startAt)
                let escalation = checkIn ? Escalation.steady : task.style.escalation
                let seconds = Int(escalation.interval(base: base, overdue: overdue).rounded())
                let tier = checkIn ? 0 : NagMessages.tier(overdue: overdue)
                repeating.append(PlannedNotification(
                    identifier: "\(prefix)every|\(seconds)|\(tier)|\(contentKey)",
                    taskID: task.id,
                    trigger: .every(seconds: seconds),
                    title: task.title,
                    body: checkIn
                        ? NagMessages.checkInRepeatingBody(title: task.title, tone: effectiveTone)
                        : NagMessages.repeatingBody(title: task.title, tier: tier, tone: effectiveTone),
                    category: category,
                    timeSensitive: task.style.breakThroughFocus
                ))
                if let tightening = escalation.nextTightening(base: base, overdue: overdue) {
                    considerWake(task.startAt.addingTimeInterval(tightening))
                }
                if !checkIn, let tierChange = NagMessages.nextTierChange(overdue: overdue) {
                    considerWake(task.startAt.addingTimeInterval(tierChange))
                }
                continue
            }

            considerWake(start)
            for (date, number) in fireDates(for: task, from: start, base: base, checkIn: checkIn, quietHours: quietHours, now: now, until: until) {
                let overdue = date.timeIntervalSince(task.startAt)
                oneOffs.append((date, PlannedNotification(
                    identifier: "\(prefix)\(Int(date.timeIntervalSince1970))|\(contentKey)",
                    taskID: task.id,
                    trigger: .at(date),
                    title: task.title,
                    body: checkIn
                        ? NagMessages.checkInBody(
                            title: task.title,
                            number: number,
                            working: date.timeIntervalSince(start),
                            tone: effectiveTone
                        )
                        : NagMessages.body(
                            title: task.title,
                            notes: task.notes,
                            number: number,
                            overdue: overdue,
                            tone: effectiveTone
                        ),
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
        checkIn: Bool = false,
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
            let escalation = checkIn ? Escalation.steady : task.style.escalation
            next = fire.addingTimeInterval(escalation.interval(base: base, overdue: overdue))
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

    public static func body(
        title: String,
        notes: String,
        number: Int,
        overdue: TimeInterval,
        tone: NagTone = .standard
    ) -> String {
        if number <= 1 {
            return notes.isEmpty ? firstStep(for: tone) : notes
        }
        let late = NagFormat.duration(overdue)
        let lines = lines(for: tone, tier: tier(overdue: overdue), number: number, late: late)
        return lines[number % lines.count]
    }

    public static func repeatingBody(title: String, tier: Int, tone: NagTone = .standard) -> String {
        switch tone {
        case .gentle:
            switch tier {
            case 0: "When you're ready, try the smallest step."
            case 1: "A small start still counts. Try two minutes."
            case 2: "This can wait for your next small step."
            default: "Be kind to yourself. One tiny step is enough."
            }
        case .standard:
            switch tier {
            case 0: "It's time. Start with the smallest step."
            case 1: "Still not done. Two minutes is enough to start."
            case 2: "Overdue. This takes less time than ignoring me."
            default: "I'm not going to stop until this is done."
            }
        case .pushy:
            switch tier {
            case 0: "Start now. Do the smallest step."
            case 1: "No more waiting. Give it two minutes."
            case 2: "It's overdue. Do the first step now."
            default: "Do it now. One tiny step, no excuses."
            }
        }
    }

    public static func checkInBody(
        title: String,
        number: Int,
        working: TimeInterval,
        tone: NagTone = .standard
    ) -> String {
        let lines = checkInLines(for: tone)
        return lines[number % lines.count]
    }

    public static func checkInRepeatingBody(title: String, tone: NagTone = .standard) -> String {
        switch tone {
        case .gentle: "How's it going? Take one small next step when you're ready."
        case .standard: "How's it going? Mark it done when it is."
        case .pushy: "Keep moving. Do the next step, then mark it done."
        }
    }

    private static func firstStep(for tone: NagTone) -> String {
        switch tone {
        case .gentle: "When you're ready, start with one small step."
        case .standard: "It's time. Start with the smallest step."
        case .pushy: "Start now. Do the smallest step."
        }
    }

    private static func lines(for tone: NagTone, tier: Int, number: Int, late: String) -> [String] {
        switch tone {
        case .gentle:
            switch tier {
            case 0: [
                "A good moment for one small step.",
                "This is still here when you're ready.",
                "Try just the first tiny step.",
            ]
            case 1: [
                "\(late) later. A two-minute start still counts.",
                "No judgment. Pick one small next step.",
                "When you're ready, do the first tiny step.",
            ]
            case 2: [
                "\(late) overdue. One small step can restart it.",
                "Be kind to yourself. Try just two minutes.",
                "This can begin with one manageable step.",
            ]
            default: [
                "Still here to help. Choose one tiny step.",
                "\(late) overdue. Start small when you're ready.",
                "A fresh start can be just one small action.",
            ]
            }
        case .standard:
            switch tier {
            case 0: [
                "Nag #\(number). Now's a good moment.",
                "Hey. This is still waiting for you.",
                "Quick one: just start it.",
            ]
            case 1: [
                "Still not done, \(late) later. Two minutes is enough to start.",
                "Nag #\(number). You said you'd do this.",
                "Overdue by \(late). Do the first tiny step.",
            ]
            case 2: [
                "Nag #\(number). Seriously, \(late) overdue.",
                "This takes less time than ignoring me.",
                "Future you is asking. \(late) overdue.",
            ]
            default: [
                "Nag #\(number). I'm not going to stop.",
                "\(late) overdue. Still here. Still nagging.",
                "Do it now and I'll go quiet.",
            ]
            }
        case .pushy:
            switch tier {
            case 0: [
                "Nag #\(number). Start the first step now.",
                "Stop waiting. Do one tiny step.",
                "Start it now. Just the first action.",
            ]
            case 1: [
                "\(late) late. Give it two minutes now.",
                "Nag #\(number). Do the first step already.",
                "It's overdue. Start with one tiny step now.",
            ]
            case 2: [
                "Nag #\(number). \(late) overdue. Act now.",
                "Enough waiting. Do one small step now.",
                "It's overdue. Take the first action now.",
            ]
            default: [
                "Nag #\(number). No more delays. Start now.",
                "\(late) overdue. Do one tiny step now.",
                "Do the first step now. No more excuses.",
            ]
            }
        }
    }

    private static func checkInLines(for tone: NagTone) -> [String] {
        switch tone {
        case .gentle: [
            "Still on it? Try one small next step when you're ready.",
            "How's it going? A tiny next step still counts.",
            "A gentle check-in. Keep going when you're ready.",
        ]
        case .standard: [
            "Still on it? Nudge when you're done.",
            "How's it going? Mark it done when it is.",
            "A gentle check-in. Keep going when you're ready.",
        ]
        case .pushy: [
            "Still on it? Do the next step, then mark it done.",
            "Keep moving. Take one small next step now.",
            "Check-in time. Finish the next step now.",
        ]
        }
    }
}
