#if os(iOS)
@preconcurrency import DeviceActivity
import Foundation
import NagCore

/// Registers DeviceActivity schedules. iOS runs the monitor extension at their boundaries even when Nag
/// isn't running. That's how schedules lock, timed unlocks expire, quiet hours start and end, and nags
/// that start later switch to repeating notifications.
public enum ActivityScheduler {
    /// DeviceActivity intervals can't be shorter than this.
    public static let minimumInterval: TimeInterval = 15 * 60

    public static func sync(state: NagState, plan: NagPlan, now: Date, calendar: Calendar) {
        let center = DeviceActivityCenter()
        var wanted: [DeviceActivityName: DeviceActivitySchedule] = [:]

        for profile in state.profiles {
            if let schedule = profile.schedule, schedule.isValid {
                wanted[DeviceActivityName(NagID.Activity.schedule(profile.id))] = daily(
                    from: schedule.startMinute,
                    to: schedule.endMinute
                )
            }
            if let until = profile.unlockedUntil, until > now {
                // Exactly the minimum length, ending when the unlock does. Computed from `until` alone so
                // later syncs produce the same schedule and leave it running.
                wanted[DeviceActivityName(NagID.Activity.relock(profile.id))] = oneOff(
                    from: until.addingTimeInterval(-minimumInterval),
                    to: until,
                    calendar: calendar
                )
            }
        }

        if let wake = plan.nextWake, wake > now {
            wanted[DeviceActivityName(NagID.Activity.wake)] = oneOff(
                from: wake,
                to: wake.addingTimeInterval(minimumInterval),
                calendar: calendar
            )
        }

        let quiet = state.settings.quietHours
        if quiet.isActive, (quiet.endMinute - quiet.startMinute + 1440) % 1440 >= 15 {
            wanted[DeviceActivityName(NagID.Activity.quiet)] = daily(from: quiet.startMinute, to: quiet.endMinute)
        }

        let stale = center.activities.filter { NagID.Activity.isNag($0.rawValue) && wanted[$0] == nil }
        if !stale.isEmpty {
            center.stopMonitoring(stale)
        }

        for (name, schedule) in wanted {
            // Restarting an activity mid-interval fires its callbacks again; leave unchanged ones alone.
            if let current = center.schedule(for: name), same(current, schedule) { continue }
            do {
                try center.startMonitoring(name, during: schedule)
            } catch {
                NagLog.error("Couldn't monitor \(name.rawValue): \(error)")
            }
        }
    }

    public static func stopAll() {
        let center = DeviceActivityCenter()
        center.stopMonitoring(center.activities.filter { NagID.Activity.isNag($0.rawValue) })
    }

    static func daily(from startMinute: Int, to endMinute: Int) -> DeviceActivitySchedule {
        DeviceActivitySchedule(
            intervalStart: DateComponents(hour: startMinute / 60, minute: startMinute % 60),
            intervalEnd: DateComponents(hour: endMinute / 60, minute: endMinute % 60),
            repeats: true
        )
    }

    static func oneOff(from start: Date, to end: Date, calendar: Calendar) -> DeviceActivitySchedule {
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        return DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(fields, from: start),
            intervalEnd: calendar.dateComponents(fields, from: end),
            repeats: false
        )
    }

    static func same(_ a: DeviceActivitySchedule, _ b: DeviceActivitySchedule) -> Bool {
        func key(_ c: DateComponents) -> [Int?] { [c.year, c.month, c.day, c.hour, c.minute, c.second] }
        return a.repeats == b.repeats
            && key(a.intervalStart) == key(b.intervalStart)
            && key(a.intervalEnd) == key(b.intervalEnd)
    }
}
#endif
