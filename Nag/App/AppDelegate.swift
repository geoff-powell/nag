import NagKit
import UIKit
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel(store: .shared)
    let router = Router()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationSync.registerCategories()
        model.start()
        return true
    }

    /// Nags should nag even while Nag is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Done and Snooze run in the background; iOS waits for this to return before suspending again.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let taskID = (userInfo[NagID.UserInfo.taskID] as? String).flatMap(UUID.init(uuidString:))
        let profileID = (userInfo[NagID.UserInfo.profileID] as? String).flatMap(UUID.init(uuidString:))
        await handle(action: response.actionIdentifier, taskID: taskID, profileID: profileID)
    }

    private func handle(action: String, taskID: UUID?, profileID: UUID?) async {
        switch action {
        case NagID.Action.done:
            if let taskID { await model.completeFromNotification(taskID) }
        case NagID.Action.snooze:
            if let taskID { await model.snoozeFromNotification(taskID) }
        case NagID.Action.scan:
            if let taskID { router.showProof(for: taskID) }
        case UNNotificationDefaultActionIdentifier:
            if let profileID {
                router.showUnlock(profileID)
            } else if let taskID {
                router.showTask(taskID)
            }
        default:
            break
        }
    }
}
