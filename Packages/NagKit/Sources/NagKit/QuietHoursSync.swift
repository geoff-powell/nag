import Foundation
import NagCore

/// Syncs only quiet hours through their own iCloud key, leaving all other settings device-local.
public final class QuietHoursSync: @unchecked Sendable {
    public static let storageKey = "nag.quietHours.v1"

    private let store: SharedStore
    private let cloud: NSUbiquitousKeyValueStore
    private let onLocalChange: @Sendable () -> Void
    private var observer: (any NSObjectProtocol)?

    /// - Parameter onLocalChange: Called after quiet hours from another device changed local state.
    public init(store: SharedStore, cloud: NSUbiquitousKeyValueStore = .default, onLocalChange: @escaping @Sendable () -> Void) {
        self.store = store
        self.cloud = cloud
        self.onLocalChange = onLocalChange
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            self?.reconcile()
        }
        cloud.synchronize()
        reconcile()
    }

    /// Last-writer-wins. With no remote value, an unstamped local default is not uploaded: nil means
    /// this device has never made a deliberate edit and must not later replace another device's value.
    public func reconcile(now: Date = .now) {
        let remoteData = cloud.data(forKey: Self.storageKey)
        let remote = remoteData.flatMap { try? JSONDecoder().decode(SyncedQuietHours.self, from: $0) }
        // Preserve data written by a future schema instead of treating it as a missing value.
        guard remoteData == nil || remote != nil else { return }

        let storedSettings = store.load().settings
        let storedLocal = storedSettings.syncedQuietHours
        let local = QuietHoursMerge.localValue(for: storedSettings, now: now)
        let merged = remote.map { QuietHoursMerge.merge(local, $0) } ?? local
        let shouldPersistLocal = merged != storedLocal
        let localQuietHoursChanged = merged.quietHours != storedLocal.quietHours

        if shouldPersistLocal {
            store.update { state in state.settings.apply(merged) }
        }

        let shouldPublish = merged.updatedAt != .distantPast && (remote == nil || merged != remote)
        if shouldPublish, let data = try? JSONEncoder().encode(merged) {
            cloud.set(data, forKey: Self.storageKey)
        }
        if localQuietHoursChanged { onLocalChange() }
    }
}
