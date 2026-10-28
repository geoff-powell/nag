import Foundation

extension UnlockRequirement.Kind {
    /// Must be redone every lock session (timers, walks, scans, phrases). Nag requirements carry over.
    public var isSessionBound: Bool {
        switch self {
        case .completeTasks, .clearDueNags: false
        case .scanKey, .walk, .wait, .typePhrase: true
        }
    }
}

extension LockSchedule {
    public var durationMinutes: Int {
        (endMinute - startMinute + 1440) % 1440
    }

    /// DeviceActivity schedules must be at least 15 minutes long.
    public var isValid: Bool {
        durationMinutes >= 15 && !weekdays.isEmpty
    }

    /// Start of the schedule window containing `date`, if `date` is inside one.
    public func windowStart(containing date: Date, calendar: Calendar) -> Date? {
        guard isValid else { return nil }
        let today = calendar.startOfDay(for: date)
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: day)
            else { continue }
            let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
            if start <= date && date < end { return start }
        }
        return nil
    }
}

extension LockProfile {
    public var session: LockSession? {
        switch status {
        case .off: nil
        case .locked(let session), .unlocked(let session, _): session
        }
    }

    /// Locked, or temporarily unlocked with the lock coming back.
    public var isEngaged: Bool {
        if case .off = status { return false }
        return true
    }

    public var isLocked: Bool {
        if case .locked = status { return true }
        return false
    }

    public var unlockedUntil: Date? {
        if case .unlocked(_, let until) = status { return until }
        return nil
    }

    /// Whether the chosen apps should be blocked right now.
    public func isShielding(at now: Date) -> Bool {
        switch status {
        case .off: false
        case .locked: true
        case .unlocked(_, let until): until <= now
        }
    }

    public var hasSessionBoundRequirements: Bool {
        requirements.contains { $0.kind.isSessionBound }
    }

    public mutating func lock(at now: Date, trigger: LockTrigger = .manual) {
        switch status {
        case .off, .unlocked: status = .locked(LockSession(startedAt: now, trigger: trigger))
        case .locked: break
        }
    }

    /// The requirements are met. Locks with timers, walks, scans or phrases open for `unlockMinutes`
    /// and then come back; locks that only need nags done switch off.
    public mutating func grantUnlock(at now: Date) {
        guard case .locked(let session) = status else { return }
        if let minutes = unlockMinutes, hasSessionBoundRequirements {
            status = .unlocked(session, until: now.addingTimeInterval(TimeInterval(minutes * 60)))
        } else {
            status = .off
        }
    }

    /// Starts the wait timer.
    public mutating func requestUnlock(at now: Date) {
        guard case .locked(var session) = status, session.unlockRequestedAt == nil else { return }
        session.unlockRequestedAt = now
        status = .locked(session)
    }

    public mutating func recordProof(_ requirementID: UUID) {
        guard case .locked(var session) = status else { return }
        session.proofs.insert(requirementID)
        status = .locked(session)
    }

    public mutating func emergencyUnlock(at now: Date) {
        status = .off
        if lockWhileNagsDue { autoLockPausedUntil = now.addingTimeInterval(3600) }
    }

    /// Ends a temporary unlock early.
    public mutating func relockNow(at now: Date) {
        guard case .unlocked(let session, _) = status else { return }
        status = .locked(LockSession(startedAt: now, trigger: session.trigger))
    }

    /// Switches on at the start of each schedule window and releases schedule-made locks when it ends.
    /// Remembers which window it handled, so earning an unlock mid-window sticks.
    /// - Parameter lookahead: Treat boundaries this close ahead as reached (callbacks can arrive early).
    @discardableResult
    public mutating func applySchedule(at now: Date, calendar: Calendar, lookahead: TimeInterval = 0) -> Bool {
        if let windowStart = schedule?.windowStart(containing: now.addingTimeInterval(lookahead), calendar: calendar) {
            guard lastScheduledLockAt != windowStart else { return false }
            lastScheduledLockAt = windowStart
            if case .off = status {
                status = .locked(LockSession(startedAt: now, trigger: .schedule))
            }
            return true
        }
        if session?.trigger == .schedule {
            status = .off
            return true
        }
        return false
    }
}

public enum LockMaintenance {
    /// Brings every lock up to date: expired unlocks come back, schedules start and stop, due nags switch
    /// on nag-triggered locks, and locks whose requirements are met unlock themselves.
    /// Returns the locks that were unlocked automatically.
    /// - Parameter tolerance: Treat unlock expiries and schedule boundaries this close ahead as reached.
    @discardableResult
    public static func run(
        _ state: inout NagState,
        now: Date,
        calendar: Calendar,
        tolerance: TimeInterval = 0
    ) -> [LockProfile] {
        let nagsDue = state.tasks.contains { $0.isOutstanding(at: now) }
        var autoUnlocked: [LockProfile] = []

        for index in state.profiles.indices {
            var profile = state.profiles[index]

            let lookahead = now.addingTimeInterval(tolerance)
            if case .unlocked(let session, let until) = profile.status, until <= lookahead {
                let stillWanted = switch session.trigger {
                case .manual: true
                case .schedule: profile.schedule?.windowStart(containing: lookahead, calendar: calendar) != nil
                case .nags: nagsDue
                }
                profile.status = stillWanted ? .locked(LockSession(startedAt: min(until, now), trigger: session.trigger)) : .off
            }

            profile.applySchedule(at: now, calendar: calendar, lookahead: tolerance)

            if profile.lockWhileNagsDue, nagsDue, case .off = profile.status,
               (profile.autoLockPausedUntil ?? .distantPast) <= now {
                profile.status = .locked(LockSession(startedAt: now, trigger: .nags))
            }

            if UnlockEvaluator.isAutoUnlockReady(profile, state: state, now: now, calendar: calendar) {
                profile.grantUnlock(at: now)
                autoUnlocked.append(profile)
            }

            state.profiles[index] = profile
        }
        return autoUnlocked
    }
}
