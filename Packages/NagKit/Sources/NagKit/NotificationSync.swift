import Foundation
import NagCore
import os
@preconcurrency import UserNotifications

@_exported import NagCore

enum NagLog {
    static let logger = Logger(subsystem: "Nag", category: "NagKit")

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

/// Keeps pending nag notifications in line with a `NagPlan`. Used on iOS and macOS.
public enum NotificationSync {
    public static func registerCategories() {
        let done = UNNotificationAction(identifier: NagID.Action.done, title: "Done", options: [])
        let started = UNNotificationAction(identifier: NagID.Action.started, title: "Started", options: [])
        let snooze15 = UNNotificationAction(identifier: NagID.Action.snooze15, title: "Snooze 15 min", options: [])
        let snooze60 = UNNotificationAction(identifier: NagID.Action.snooze60, title: "Snooze 1 hr", options: [])
        let scan = UNNotificationAction(identifier: NagID.Action.scan, title: "Scan to finish", options: [.foreground])
        let undo = UNNotificationAction(identifier: NagID.Action.undo, title: "Undo", options: [])
        func category(_ identifier: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories([
            category(NagID.Category.nag, [done, started, snooze15, snooze60]),
            category(NagID.Category.nagNoSnooze, [done, started]),
            category(NagID.Category.proof, [scan, started, snooze15, snooze60]),
            category(NagID.Category.proofNoSnooze, [scan, started]),
            category(NagID.Category.alert, []),
            category(NagID.Category.undo, [undo]),
        ])
    }

    public static func requestAuthorization() async -> Bool {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: options)) ?? false
    }

    public static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Adds what's missing, removes what's stale, and leaves unchanged notifications alone so repeating
    /// triggers keep their rhythm. Also clears delivered nags for anything no longer nagging.
    public static func apply(_ plan: NagPlan, tasks: [NagTask], now: Date) async {
        let center = UNUserNotificationCenter.current()
        let pendingIDs = Set(
            await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter { $0.hasPrefix(NagID.nagNotificationPrefix) }
        )
        let wantedIDs = Set(plan.notifications.map(\.identifier))

        let stale = pendingIDs.subtracting(wantedIDs)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }
        for notification in plan.notifications where !pendingIDs.contains(notification.identifier) {
            do {
                try await center.add(request(for: notification))
            } catch {
                NagLog.error("Couldn't schedule nag: \(error)")
            }
        }

        let nagging = Set(tasks.filter { $0.isNagging(at: now) }.map(\.id.uuidString))
        let finished = await center.deliveredNotifications().compactMap { delivered -> String? in
            let request = delivered.request
            guard request.identifier.hasPrefix(NagID.nagNotificationPrefix) else { return nil }
            let taskID = request.content.userInfo[NagID.UserInfo.taskID] as? String
            return taskID.map(nagging.contains) == true ? nil : request.identifier
        }
        if !finished.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: finished)
        }

        try? await center.setBadgeCount(plan.outstandingCount)
    }

    static func request(for notification: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = notification.category
        content.threadIdentifier = notification.taskID.uuidString
        content.userInfo = [NagID.UserInfo.taskID: notification.taskID.uuidString]
        content.interruptionLevel = notification.timeSensitive ? .timeSensitive : .active
        content.relevanceScore = 1

        let trigger: UNNotificationTrigger
        switch notification.trigger {
        case .at(let date):
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .every(let seconds):
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(60, seconds)), repeats: true)
        }
        return UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger)
    }

    static func alertRequest(title: String, body: String, profileID: UUID?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = NagID.Category.alert
        content.interruptionLevel = .timeSensitive
        if let profileID {
            content.userInfo = [NagID.UserInfo.profileID: profileID.uuidString]
        }
        return UNNotificationRequest(identifier: "nag.alert.\(UUID().uuidString)", content: content, trigger: nil)
    }

    /// Shows a notification right away. Tapping one with a `profileID` opens that lock's unlock screen.
    public static func alert(title: String, body: String, profileID: UUID? = nil) async {
        try? await UNUserNotificationCenter.current().add(alertRequest(title: title, body: body, profileID: profileID))
    }

    public static func undoFollowUp(task: NagTask) async {
        let content = UNMutableNotificationContent()
        content.title = "Marked \(task.title) done"
        content.body = "Tap Undo if that was a mistake."
        content.sound = .default
        content.categoryIdentifier = NagID.Category.undo
        content.interruptionLevel = .active
        content.userInfo = [NagID.UserInfo.taskID: task.id.uuidString]
        let request = UNNotificationRequest(
            identifier: "nag.undo.\(task.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    public static func removeDeliveredUndoFollowUp(taskID: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["nag.undo.\(taskID.uuidString)"]
        )
    }

    /// Callback variant for extension entry points that must answer synchronously.
    public static func alert(title: String, body: String, profileID: UUID?, completion: @escaping @Sendable () -> Void) {
        UNUserNotificationCenter.current().add(alertRequest(title: title, body: body, profileID: profileID)) { _ in
            completion()
        }
    }
}
