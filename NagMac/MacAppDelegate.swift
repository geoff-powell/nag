import AppKit
import NagKit
@preconcurrency import UserNotifications

/// Owns the model and everything that enforces it on the Mac: the app blocker, the floating panels and
/// the main window.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = MacModel(store: .shared)
    private lazy var mainWindow = MainWindowController(model: model)
    private lazy var shieldPanel = ShieldPanelController()
    private lazy var nagPanel = NagPanelController(model: model)
    private lazy var blocker = AppBlocker { [weak self] app, profile in
        self?.showShield(for: app, profile: profile)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        NotificationSync.registerCategories()

        model.openMainWindow = { [weak self] in self?.mainWindow.show() }
        model.onChange = { [weak self] in self?.enforce() }
        model.start()

        if !model.hasLaunchedBefore {
            model.markLaunched()
            mainWindow.show()
            Task { await model.requestNotifications() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    /// Strict locks keep Nag running, otherwise quitting Nag would be the way out. Logging out and
    /// shutting down are always allowed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let isSystemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard !isSystemQuit, let strict = model.strictEngagedLock else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "“\(strict.name)” is in strict mode"
        alert.informativeText = "Nag can't quit while a strict lock is on. Unlock it first."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Unlock…")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            model.showUnlock(strict.id)
        }
        return .terminateCancel
    }

    private func enforce() {
        let now = Date()
        blocker.update(profiles: model.state.profiles, now: now)
        nagPanel.refresh(now: now)
        if !model.state.profiles.contains(where: { $0.isShielding(at: now) }) {
            shieldPanel.close()
        }
    }

    private func showShield(for app: BlockedApp, profile: LockProfile) {
        let remaining = model.evaluate(profile, now: .now).filter { !$0.isMet }.map(\.title)
        shieldPanel.show(app: app, profile: profile, remaining: remaining) { [weak self] in
            self?.model.showUnlock(profile.id)
        }
    }

    // MARK: - Notifications

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

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
            if let taskID { model.complete(taskID) }
        case NagID.Action.snooze:
            if let taskID { model.snooze(taskID) }
        default:
            if let profileID {
                model.showUnlock(profileID)
            } else {
                model.section = .nags
                mainWindow.show()
            }
        }
        await model.waitForNotificationSync()
    }
}
