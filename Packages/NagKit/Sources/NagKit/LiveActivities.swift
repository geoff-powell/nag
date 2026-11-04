#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation
import NagCore
import UIKit

public struct NagActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var content: NagActivityContent

        public init(content: NagActivityContent) {
            self.content = content
        }
    }

    public var taskID: UUID
    public var title: String
    /// Stored in the static attributes so a later app launch can enforce the eight-hour cap.
    public var startedAt: Date

    public init(taskID: UUID, title: String, startedAt: Date) {
        self.taskID = taskID
        self.title = title
        self.startedAt = startedAt
    }
}

public struct LockActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var content: LockActivityContent

        public init(content: LockActivityContent) {
            self.content = content
        }
    }

    public var profileID: UUID
    public var name: String
    public var startedAt: Date

    public init(profileID: UUID, name: String, startedAt: Date) {
        self.profileID = profileID
        self.name = name
        self.startedAt = startedAt
    }
}

/// App-process ownership of ActivityKit lifecycle. Nag has no push server, so activities can only be
/// started or refreshed while the iPhone app is running. SharedStore remains the source of truth.
@MainActor public enum LiveActivities {
    private static var cappedNagTargets = LiveActivityCappedTargets()
    private static var cappedLockTargets = LiveActivityCappedTargets()

    public static var areEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    public static func reconcile(state: NagState, now: Date, calendar: Calendar) async {
        guard state.settings.liveActivitiesEnabled, areEnabled else {
            await endAll()
            return
        }

        let isForegroundActive = UIApplication.shared.applicationState == .active
        let snapshot = WidgetSnapshot.make(
            from: state,
            now: now,
            calendar: calendar,
            limit: state.tasks.count
        )
        let nagTarget = snapshot.due.lazy.compactMap { summary -> NagActivityContent? in
            guard summary.isOverdue, !summary.isStarted, let task = state.task(summary.id) else { return nil }
            return NagActivityContent.make(
                task: task,
                state: state,
                tone: state.settings.nagTone,
                now: now,
                calendar: calendar
            )
        }.first
        cappedNagTargets.select(nagTarget?.taskID)
        await reconcileNag(
            nagTarget,
            state: state,
            now: now,
            calendar: calendar,
            mayReplace: isForegroundActive
        )

        let lockTarget = snapshot.locks.lazy.compactMap { summary -> LockActivityContent? in
            state.profile(summary.id).flatMap {
                LockActivityContent.make(profile: $0, state: state, now: now, calendar: calendar)
            }
        }.first
        cappedLockTargets.select(lockTarget?.profileID)
        await reconcileLock(
            lockTarget,
            state: state,
            now: now,
            calendar: calendar,
            mayReplace: isForegroundActive
        )
    }

    public static func endAll() async {
        for activity in Activity<NagActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        for activity in Activity<LockActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func reconcileNag(
        _ target: NagActivityContent?,
        state: NagState,
        now: Date,
        calendar: Calendar,
        mayReplace: Bool
    ) async {
        var matching: Activity<NagActivityAttributes>?
        for activity in Activity<NagActivityAttributes>.activities {
            let expired = NagActivityContent.dismissAt(start: activity.attributes.startedAt) <= now
            if expired {
                if activity.attributes.taskID == target?.taskID {
                    cappedNagTargets.recordExpired(activity.attributes.taskID)
                }
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            if activity.attributes.taskID == target?.taskID, matching == nil {
                matching = activity
                continue
            }
            let stillQualifies = state.task(activity.attributes.taskID).flatMap {
                NagActivityContent.make(
                    task: $0,
                    state: state,
                    tone: state.settings.nagTone,
                    now: now,
                    calendar: calendar
                )
            } != nil
            if mayReplace || !stillQualifies {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        guard let target else { return }
        let content = ActivityContent(
            state: NagActivityAttributes.ContentState(content: target),
            staleDate: target.staleDate,
            relevanceScore: 1
        )
        if let matching {
            await matching.update(content)
        } else if mayReplace, cappedNagTargets.allowsStarting(target.taskID) {
            do {
                _ = try Activity.request(
                    attributes: NagActivityAttributes(taskID: target.taskID, title: target.title, startedAt: now),
                    content: content,
                    pushType: nil
                )
            } catch {
                NagLog.error("Could not start nag Live Activity: \(error.localizedDescription)")
            }
        }
    }

    private static func reconcileLock(
        _ target: LockActivityContent?,
        state: NagState,
        now: Date,
        calendar: Calendar,
        mayReplace: Bool
    ) async {
        var matching: Activity<LockActivityAttributes>?
        for activity in Activity<LockActivityAttributes>.activities {
            let expired = NagActivityContent.dismissAt(start: activity.attributes.startedAt) <= now
            if expired {
                if activity.attributes.profileID == target?.profileID {
                    cappedLockTargets.recordExpired(activity.attributes.profileID)
                }
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            if activity.attributes.profileID == target?.profileID, matching == nil {
                matching = activity
                continue
            }
            let stillQualifies = state.profile(activity.attributes.profileID).flatMap {
                LockActivityContent.make(profile: $0, state: state, now: now, calendar: calendar)
            } != nil
            if mayReplace || !stillQualifies {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        guard let target else { return }
        let content = ActivityContent(
            state: LockActivityAttributes.ContentState(content: target),
            staleDate: target.staleDate,
            relevanceScore: 0
        )
        if let matching {
            await matching.update(content)
        } else if mayReplace, cappedLockTargets.allowsStarting(target.profileID) {
            do {
                _ = try Activity.request(
                    attributes: LockActivityAttributes(profileID: target.profileID, name: target.name, startedAt: now),
                    content: content,
                    pushType: nil
                )
            } catch {
                NagLog.error("Could not start lock Live Activity: \(error.localizedDescription)")
            }
        }
    }
}
#endif
