import AppIntents
import CloudKit
import NagKit
import UIKit
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = UITesting.isActive ? UITesting.makeModel() : AppModel(store: .shared)
    let router = Router()

    /// SwiftUI wraps the app delegate, so `UIApplication.shared.delegate` isn't this object. The scene
    /// delegate reaches it through here.
    private(set) static weak var current: AppDelegate?

    override init() {
        super.init()
        Self.current = self
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

    /// A scene delegate, so Nag hears about accepted CloudKit share invitations.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        acceptShare(metadata)
    }

    func acceptShare(_ metadata: CKShare.Metadata) {
        guard let buddy = model.buddy else { return }
        router.showBuddy()
        Task { await buddy.accept(metadata) }
    }

    /// CloudKit pushes when a buddy leaves a nudge. Uses the completion-handler form for the same
    /// main-thread reason as the notification response below.
    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping @Sendable (UIBackgroundFetchResult) -> Void
    ) {
        guard CloudBuddyService.isCloudKitNotification(userInfo) else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await self.model.buddy?.refresh()
            completionHandler(.newData)
        }
    }

    func backgroundRefresh() async {
        await model.buddy?.refresh()
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
        if let option = SnoozeOption.option(forAction: action), let taskID {
            await model.snoozeFromNotification(taskID, minutes: option.minutes)
            return
        }
        switch action {
        case NagID.Action.done:
            if let taskID { await model.completeFromNotification(taskID) }
        case NagID.Action.started:
            if let taskID { await model.startFromNotification(taskID) }
        case NagID.Action.snooze:
            if let taskID { await model.snoozeFromNotification(taskID) }
        case NagID.Action.undo:
            if let taskID { await model.undoFromNotification(taskID) }
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
