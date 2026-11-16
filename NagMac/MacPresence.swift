import AppKit
import CoreGraphics
import NagKit

/// Whether someone is at this Mac: the screen is unlocked, it's awake, and there's been recent input.
/// Calls `onChange` as soon as the screen locks, the Mac sleeps or either comes back, so going idle
/// reaches the iPhone without waiting for the next tick.
@MainActor
final class MacPresence {
    private(set) var screenLocked = false
    private(set) var asleep = false
    var onChange: (() -> Void)?

    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(distributed, "com.apple.screenIsLocked") { $0.screenLocked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.screenLocked = false }
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.asleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.asleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.asleep = false }
        // Fast user switching away counts as locked.
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.screenLocked = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.screenLocked = false }
    }

    /// Seconds since the last keyboard, mouse or trackpad event in this login session.
    var secondsSinceInput: TimeInterval {
        // ~0 is kCGAnyInputEventType.
        guard let anyInput = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ update: @escaping @MainActor @Sendable (MacPresence) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.onChange?()
            }
        }
        observers.append((center, token))
    }
}
