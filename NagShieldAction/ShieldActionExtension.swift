import ManagedSettings
import NagKit

/// Handles the shield's buttons. A shield can't open another app, so "Unlock in Nag" posts a notification
/// that opens the lock's unlock screen when tapped, then closes the blocked app.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(to: action, profile: lockingProfile(application: application), completionHandler: completionHandler)
    }

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(to: action, profile: lockingProfile(webDomain: webDomain), completionHandler: completionHandler)
    }

    override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(to: action, profile: lockingProfile(category: category), completionHandler: completionHandler)
    }

    private func lockingProfile(
        application: ApplicationToken? = nil,
        category: ActivityCategoryToken? = nil,
        webDomain: WebDomainToken? = nil
    ) -> LockProfile? {
        ShieldController.profile(
            in: SharedStore.shared.load(),
            now: .now,
            application: application,
            category: category,
            webDomain: webDomain
        )
    }

    private func respond(
        to action: ShieldAction,
        profile: LockProfile?,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            nonisolated(unsafe) let respond = completionHandler
            NotificationSync.alert(
                title: "Tap to unlock \(profile?.name ?? "your apps")",
                body: "Nag will show you what's left to do.",
                profileID: profile?.id
            ) {
                respond(.close)
            }
        default:
            // "Close", plus any submenu items newer iOS versions add.
            completionHandler(.close)
        }
    }
}
