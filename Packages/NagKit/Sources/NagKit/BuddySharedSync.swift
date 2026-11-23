import Foundation
import NagCore

/// Syncs which nags and locks are shared with a buddy, through its own iCloud key-value entry.
///
/// Kept apart from `CloudTaskSync` so the synced nag payload, which older builds re-encode, never
/// carries a sharing flag. Older builds don't know this key and leave it alone. Last writer wins.
public final class BuddySharedSync: @unchecked Sendable {
    private let store: SharedStore
    private let cloud: NSUbiquitousKeyValueStore
    private let onLocalChange: @Sendable () -> Void
    private var observer: (any NSObjectProtocol)?

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
        reconcile()
    }

    public func reconcile() {
        let remoteData = cloud.data(forKey: BuddySharedItems.storageKey)
        let remote = remoteData.flatMap { try? JSONDecoder().decode(BuddySharedItems.self, from: $0) }
        // Leave data from a future schema alone.
        guard remoteData == nil || remote != nil else { return }

        let local = store.load().buddy.shared
        let merged = remote.map { BuddySharedItems.merge(local, $0) } ?? local
        if merged != local {
            store.update { $0.buddy.shared = merged }
        }
        if merged.updatedAt != .distantPast, merged != remote, let data = try? JSONEncoder().encode(merged) {
            cloud.set(data, forKey: BuddySharedItems.storageKey)
        }
        if merged.ids != local.ids { onLocalChange() }
    }
}
