import Foundation
import NagCore

/// Publishes this device's heartbeat to iCloud key-value storage and mirrors every device's heartbeat
/// into the shared store, where `NagEngine` (in the app and the DeviceActivity monitor) plans with it.
///
/// All devices share one small map under one key. Each writes only its own entry, so if two writes cross
/// and one is lost, the loser notices on the next change and writes its entry again. Without the iCloud
/// entitlement nothing arrives, and the iPhone nags as usual.
public final class DeviceHeartbeatSync: @unchecked Sendable {
    public static let storageKey = "nag.devices.v1"
    static let deviceIDKey = "nag.deviceID"

    public let deviceID: String
    private let platform: DevicePlatform
    private let store: SharedStore
    private let cloud: NSUbiquitousKeyValueStore
    private let onRemoteChange: @Sendable () -> Void
    private var observer: (any NSObjectProtocol)?
    private var lastPublished: DeviceHeartbeat?

    /// - Parameter onRemoteChange: Called after another device's heartbeat changed what's in the store.
    public init(
        platform: DevicePlatform,
        store: SharedStore,
        cloud: NSUbiquitousKeyValueStore = .default,
        defaults: UserDefaults = .standard,
        onRemoteChange: @escaping @Sendable () -> Void
    ) {
        if let existing = defaults.string(forKey: Self.deviceIDKey) {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Self.deviceIDKey)
        }
        self.platform = platform
        self.store = store
        self.cloud = cloud
        self.onRemoteChange = onRemoteChange
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
        ) { [weak self] notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            guard keys?.contains(Self.storageKey) ?? true else { return }
            self?.reconcile()
        }
        cloud.synchronize()
        reconcile()
    }

    /// Copies iCloud's heartbeats into the store, and rewrites this device's entry if a crossing write
    /// from another device dropped it.
    public func reconcile(now: Date = .now) {
        guard let remote = readRemote() else { return }
        if let lastPublished, remote[deviceID] != lastPublished,
           lastPublished.activity == .idle || lastPublished.activeUntil > now {
            write(DeviceHandoff.merging(lastPublished, into: remote, now: now))
        }
        mirror(remote)
    }

    /// Publishes `activity` if it changes what other devices see, or an active heartbeat is due a refresh.
    /// Cheap to call often: it writes at most every `DeviceHandoff.refreshInterval` while active.
    public func publish(_ activity: DeviceHeartbeat.Activity, now: Date = .now) {
        guard let remote = readRemote() else { return }
        guard let heartbeat = DeviceHandoff.heartbeatToPublish(
            previous: lastPublished ?? remote[deviceID],
            deviceID: deviceID,
            platform: platform,
            activity: activity,
            now: now
        ) else { return }
        lastPublished = heartbeat
        let merged = DeviceHandoff.merging(heartbeat, into: remote, now: now)
        write(merged)
        // Going idle matters most and often happens just before sleep, so ask iCloud to send it now.
        if activity == .idle { cloud.synchronize() }
        mirror(merged)
    }

    /// `nil` when the value can't be read, such as one written by a newer version. Then nothing is
    /// published over it, and the iPhone nags as usual.
    private func readRemote() -> [String: DeviceHeartbeat]? {
        guard let data = cloud.data(forKey: Self.storageKey) else { return [:] }
        return try? JSONDecoder().decode([String: DeviceHeartbeat].self, from: data)
    }

    private func write(_ devices: [String: DeviceHeartbeat]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        cloud.set(data, forKey: Self.storageKey)
    }

    private func mirror(_ devices: [String: DeviceHeartbeat]) {
        let sorted = devices.values.sorted { $0.deviceID < $1.deviceID }
        let deviceID = deviceID
        let othersChanged = store.update { state -> Bool in
            guard state.devices != sorted else { return false }
            let before = state.devices.filter { $0.deviceID != deviceID }
            state.devices = sorted
            return before != sorted.filter { $0.deviceID != deviceID }
        }
        if othersChanged { onRemoteChange() }
    }
}
