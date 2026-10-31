#if os(iOS)
import Foundation
import NagCore

/// Brings shields, DeviceActivity schedules and notifications in line with the stored state.
///
/// Runs in the app and in the monitor extension, so it's nonisolated and quick. Every entry point
/// (launch, foreground, notification actions, background refresh, DeviceActivity callbacks) ends here.
public enum NagEngine {
    /// - Parameter tolerance: How early a DeviceActivity callback may arrive. Schedule boundaries and
    ///   unlock expiries within this window are treated as reached.
    public static func sync(
        store: SharedStore = .shared,
        now: Date = .now,
        calendar: Calendar = .current,
        tolerance: TimeInterval = 0
    ) async {
        let (state, autoUnlocked) = store.update { state in
            let unlocked = LockMaintenance.run(&state, now: now, calendar: calendar, tolerance: tolerance)
            return (state, unlocked)
        }

        ShieldController.apply(state.profiles, now: now)

        // Repeating notifications can't pause for quiet hours on their own; they rely on the quiet-hours
        // DeviceActivity, which needs Screen Time access.
        let planner = NagPlanner(
            allowRepeating: state.settings.screenTimeApproved || !state.settings.quietHours.isActive,
            calendar: calendar
        )
        let plan = planner.plan(
            tasks: state.tasks,
            quietHours: state.settings.quietHours,
            tone: state.settings.nagTone,
            now: now
        )

        if state.settings.screenTimeApproved {
            ActivityScheduler.sync(state: state, plan: plan, now: now, calendar: calendar)
        }
        await NotificationSync.apply(plan, tasks: state.tasks, now: now)

        for profile in autoUnlocked {
            await NotificationSync.alert(
                title: "\(profile.name) unlocked",
                body: unlockedMessage(for: profile),
                profileID: profile.id
            )
        }
    }

    public static func unlockedMessage(for profile: LockProfile) -> String {
        if let until = profile.unlockedUntil {
            return "Nice work. Your apps are open until \(until.formatted(date: .omitted, time: .shortened))."
        }
        return "Nice work. Everything's done, so your apps are open."
    }

    /// For DeviceActivity callbacks, which are synchronous: runs `sync` and waits for it, bounded so the
    /// extension is never stuck.
    public static func handleActivityCallback(store: SharedStore = .shared) {
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await sync(store: store, tolerance: 90)
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 20)
    }
}
#endif
