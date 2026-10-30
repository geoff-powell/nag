import AppIntents
import NagKit
import UIKit
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = UITesting.isActive ? UITesting.makeModel() : AppModel(store: .shared)
    let router = Router()

    override init() {
        super.init()
        // Shortcuts and Siri can launch Nag in the background to run an intent, so register before launch finishes.
        let model = model
        AppDependencyManager.shared.add(dependency: model)
    }

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

    /// Done and Snooze run in the background; iOS waits for the completion handler before suspending again.
    ///
    /// Uses the completion-handler form rather than `async`: the compiler-generated thunk for a
    /// `nonisolated async` delegate method calls the completion handler off the main thread, which
    /// trips UIKit's main-thread assertion and crashes the app when a notification is tapped.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let taskID = (userInfo[NagID.UserInfo.taskID] as? String).flatMap(UUID.init(uuidString:))
        let profileID = (userInfo[NagID.UserInfo.profileID] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        Task { @MainActor in
            await self.handle(action: action, taskID: taskID, profileID: profileID)
            completionHandler()
        }
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
