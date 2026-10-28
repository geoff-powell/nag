import AppKit
import NagKit

/// Enforces Mac locks. macOS has no Screen Time shields for third-party apps, so Nag watches app
/// launches and activations and hides (or, in strict mode, quits) anything a lock is blocking.
@MainActor
final class AppBlocker {
    private struct Rule {
        let profile: LockProfile
        let app: BlockedApp
    }

    private var rules: [String: Rule] = [:]
    private var observers: [any NSObjectProtocol] = []
    private let onBlocked: (BlockedApp, LockProfile) -> Void

    init(onBlocked: @escaping (BlockedApp, LockProfile) -> Void) {
        self.onBlocked = onBlocked
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                MainActor.assumeIsolated {
                    guard let pid, let running = NSRunningApplication(processIdentifier: pid) else { return }
                    self?.enforce(on: running, announce: true)
                }
            })
        }
    }

    /// Recomputes what's blocked. Newly blocked apps that are already running are dealt with right away.
    func update(profiles: [LockProfile], now: Date) {
        var next: [String: Rule] = [:]
        for profile in profiles where profile.isShielding(at: now) {
            for app in profile.blockedApps where BlockedApp.isBlockable(app.bundleID) {
                // Strict wins when two locks block the same app.
                if let existing = next[app.bundleID], existing.profile.strict { continue }
                next[app.bundleID] = Rule(profile: profile, app: app)
            }
        }
        let newlyBlocked = Set(next.keys).subtracting(rules.keys)
        rules = next

        guard !newlyBlocked.isEmpty else { return }
        for running in NSWorkspace.shared.runningApplications {
            if let bundleID = running.bundleIdentifier, newlyBlocked.contains(bundleID) {
                enforce(on: running, announce: running.isActive)
            }
        }
    }

    var isBlockingAnything: Bool { !rules.isEmpty }

    private func enforce(on running: NSRunningApplication, announce: Bool) {
        guard let bundleID = running.bundleIdentifier, let rule = rules[bundleID] else { return }
        if rule.profile.strict {
            running.terminate()
        } else {
            running.hide()
            // Apps that are still finishing launching can ignore the first hide.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !running.isHidden { running.hide() }
            }
        }
        if announce {
            onBlocked(rule.app, rule.profile)
        }
    }
}
