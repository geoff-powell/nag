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
        case .locked(var session):
            // Locking by hand while a Focus holds the lock takes it over, so ending the Focus can't
            // switch off a lock the user chose to turn on.
            if trigger == .manual, session.trigger == .focus {
                session.trigger = .manual
                status = .locked(session)
            }
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
    public mutating func applySchedule(
        at now: Date,
        calendar: Calendar,
        lookahead: TimeInterval = 0,
        focusActive: Bool = false
    ) -> Bool {
        if let windowStart = schedule?.windowStart(containing: now.addingTimeInterval(lookahead), calendar: calendar) {
            guard lastScheduledLockAt != windowStart else { return false }
            lastScheduledLockAt = windowStart
            if case .off = status {
                status = .locked(LockSession(startedAt: now, trigger: .schedule))
            }
            return true
        }
        if session?.trigger == .schedule {
            if focusActive {
                replaceSessionTrigger(with: .focus)
            } else {
                status = .off
            }
            return true
        }
        return false
    }

    /// Switches on when a Focus filter starts asking for this lock, and releases Focus-made locks when
    /// the Focus ends. Never switches off a lock that something else turned on.
    @discardableResult
    public mutating func applyFocus(
        _ filter: FocusFilter,
        at now: Date,
        scheduleActive: Bool = false
    ) -> Bool {
        if let focusStart = filter.lockStarts[id] {
            guard lastFocusLockAt != focusStart else { return false }
            lastFocusLockAt = focusStart
            if case .off = status {
                status = .locked(LockSession(startedAt: now, trigger: .focus))
            }
            return true
        }
        if session?.trigger == .focus {
            if scheduleActive {
                replaceSessionTrigger(with: .schedule)
            } else {
                status = .off
            }
            return true
        }
        return false
    }

    private mutating func replaceSessionTrigger(with trigger: LockTrigger) {
        switch status {
        case .off:
            break
        case .locked(var session):
            session.trigger = trigger
            status = .locked(session)
        case .unlocked(var session, let until):
            session.trigger = trigger
            status = .unlocked(session, until: until)
        }
    }
}

public enum LockMaintenance {
    /// Brings every lock up to date: expired unlocks come back, schedules and Focus filters start and
    /// stop, due nags switch on nag-triggered locks, and locks whose requirements are met unlock themselves.
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

        // Forget locks deleted while a Focus was asking for them.
        let profileIDs = Set(state.profiles.map(\.id))
        state.settings.focusFilter.lockStarts = state.settings.focusFilter.lockStarts.filter { profileIDs.contains($0.key) }

        for index in state.profiles.indices {
            var profile = state.profiles[index]

            let lookahead = now.addingTimeInterval(tolerance)
            let scheduleActive = profile.schedule?.windowStart(containing: lookahead, calendar: calendar) != nil
            let focusActive = state.settings.focusFilter.lockStarts[profile.id] != nil

            if case .unlocked(let session, let until) = profile.status, until <= lookahead {
                let nextTrigger: LockTrigger? = switch session.trigger {
                case .manual: .manual
                case .schedule: scheduleActive ? .schedule : (focusActive ? .focus : nil)
                case .nags: nagsDue ? .nags : (focusActive ? .focus : (scheduleActive ? .schedule : nil))
                case .focus: focusActive ? .focus : (scheduleActive ? .schedule : nil)
                }
                if let nextTrigger {
                    profile.status = .locked(LockSession(startedAt: min(until, now), trigger: nextTrigger))
                } else {
                    profile.status = .off
                }
            }

            profile.applySchedule(at: now, calendar: calendar, lookahead: tolerance, focusActive: focusActive)
            profile.applyFocus(state.settings.focusFilter, at: now, scheduleActive: scheduleActive)

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
