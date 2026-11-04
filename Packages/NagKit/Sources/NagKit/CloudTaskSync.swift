import Foundation
import NagCore

/// Syncs nags between the iPhone and the Mac through iCloud key-value storage.
///
/// Small and simple, which suits a personal list: both sides merge with `TaskMerge`, so devices converge
/// whatever order changes arrive in. Locks and keys aren't synced; they're specific to each device.
/// Without the iCloud entitlement this quietly does nothing.
public final class CloudTaskSync: @unchecked Sendable {
    public static let storageKey = "nag.tasks.v1"
    /// Place triggers by nag ID, kept apart from the nags so builds that predate places (which drop
    /// fields they don't know when saving) can't erase them. See `PlaceTriggerRecord`.
    public static let placeTriggersKey = "nag.placeTriggers.v1"

    private let store: SharedStore
    private let cloud: NSUbiquitousKeyValueStore
    private let onLocalChange: @Sendable () -> Void
    private var observer: (any NSObjectProtocol)?

    /// - Parameter onLocalChange: Called after changes from another device were merged into local state.
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

    /// Merges the local and iCloud copies and writes back to whichever side is behind.
    public func reconcile(now: Date = .now) {
        let remoteTasks = cloud.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(SyncedTasks.self, from: $0) }
            ?? SyncedTasks()
        let remoteTriggers = cloud.data(forKey: Self.placeTriggersKey)
            .flatMap { try? JSONDecoder().decode([String: PlaceTriggerRecord].self, from: $0) }
            ?? [:]
        let remote = remoteTasks.applyingPlaceTriggers(remoteTriggers)

        var localChanged = false
        let merged = store.update { state -> SyncedTasks in
            let local = state.syncedTasks
            let merged = TaskMerge.merge(local, remote, now: now)
            if merged != local {
                state.apply(merged)
                localChanged = merged.tasks != local.tasks
            }
            return merged
        }

        if merged != remoteTasks, let data = try? JSONEncoder().encode(merged) {
            cloud.set(data, forKey: Self.storageKey)
        }
        let triggers = merged.placeTriggerRecords
        if triggers != remoteTriggers, let data = try? JSONEncoder().encode(triggers) {
            cloud.set(data, forKey: Self.placeTriggersKey)
        }
        if localChanged { onLocalChange() }
    }
}
