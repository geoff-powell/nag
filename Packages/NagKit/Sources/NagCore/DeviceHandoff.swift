import Foundation

/// The device a heartbeat came from.
public enum DevicePlatform: String, Codable, Hashable, Sendable {
    case iPhone
    case mac
    /// A platform a newer version added. Never takes over nagging.
    case unknown

    /// Unknown future platforms decode instead of making every heartbeat unreadable.
    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = DevicePlatform(rawValue: rawValue) ?? .unknown
    }
}

/// One device saying whether someone is using it. Synced through iCloud so the iPhone can ease off while
/// the Mac is carrying the nag.
public struct DeviceHeartbeat: Codable, Hashable, Sendable {
    public enum Activity: String, Codable, Hashable, Sendable {
        case active
        case idle
    }

    /// Stable for one install of Nag on one device.
    public var deviceID: String
    public var platform: DevicePlatform
    public var activity: Activity
    /// When the device wrote this, by its own clock.
    public var updatedAt: Date
    /// After this the heartbeat means nothing, even if the device never wrote "idle". Equal to
    /// `updatedAt` for an idle heartbeat.
    public var activeUntil: Date

    public init(deviceID: String, platform: DevicePlatform, activity: Activity, updatedAt: Date, activeUntil: Date) {
        self.deviceID = deviceID
        self.platform = platform
        self.activity = activity
        self.updatedAt = updatedAt
        self.activeUntil = activeUntil
    }
}

/// Rules for handing nagging over to the Mac while it's in use.
///
/// The iPhone pre-schedules its notifications, so it can't rely on noticing the Mac go idle in time.
/// Instead the Mac promises it's in use until `activeUntil`, and the iPhone plans sparse reminders up to
/// that moment and its normal escalation after it. If the Mac stops refreshing, the iPhone is back to
/// full nagging within `activeValidity`, with no wake-up needed. Anything doubtful (no heartbeat, an
/// expired one, a clock that looks wrong) means full nagging: two devices nagging beats none.
public enum DeviceHandoff {
    /// How often an active Mac rewrites its heartbeat. iCloud key-value storage is rate limited, so this
    /// is kept well above the Mac's tick.
    public static let refreshInterval: TimeInterval = 5 * 60
    /// How long an active heartbeat holds. Three refresh intervals, so one or two late iCloud deliveries
    /// don't flip the iPhone back to full nagging, while a Mac that vanishes without saying so (crash,
    /// lost network) only holds the iPhone back for this long.
    public static let activeValidity: TimeInterval = 15 * 60
    /// No keyboard, mouse or trackpad input for this long and the Mac counts as idle.
    public static let inputIdleThreshold: TimeInterval = 5 * 60
    /// Heartbeats stamped further than this into the future come from a clock that can't be trusted.
    public static let maxClockSkew: TimeInterval = 5 * 60
    /// Devices not heard from for this long are dropped from the synced map.
    public static let pruneAfter: TimeInterval = 7 * 24 * 3600
    /// While the Mac has it, the iPhone reminds this often at most (and never more often than the nag's
    /// own interval).
    public static let reducedInterval: TimeInterval = 30 * 60

    public static let explanation = "While you're using your Mac, it carries the nag with its panel and notifications, and your iPhone only reminds you now and then. Once the Mac is locked, asleep or left alone for a few minutes, your iPhone nags as usual again."

    /// The moment the iPhone's reduced cadence ends, or `nil` to nag as usual.
    ///
    /// Only active Macs count, so a Mac never eases off because of the iPhone. A heartbeat stamped
    /// implausibly far in the future is ignored, and none can claim more than `activeValidity` from
    /// `now` or from when it was written.
    public static func handoffUntil(heartbeats: [DeviceHeartbeat], now: Date) -> Date? {
        heartbeats
            .compactMap { effectiveActiveUntil(of: $0, now: now) }
            .max()
    }

    static func effectiveActiveUntil(of heartbeat: DeviceHeartbeat, now: Date) -> Date? {
        guard heartbeat.platform == .mac,
              heartbeat.activity == .active,
              heartbeat.updatedAt <= now.addingTimeInterval(maxClockSkew)
        else { return nil }
        let until = min(
            heartbeat.activeUntil,
            heartbeat.updatedAt.addingTimeInterval(activeValidity),
            now.addingTimeInterval(activeValidity)
        )
        return until > now ? until : nil
    }

    /// Whether the Mac should count as in use right now. It also has to be able to nag: with no panel
    /// and no notifications allowed, handing over would leave nobody nagging.
    public static func macActivity(
        secondsSinceInput: TimeInterval,
        screenLocked: Bool,
        asleep: Bool,
        canNag: Bool,
        enabled: Bool
    ) -> DeviceHeartbeat.Activity {
        guard enabled, canNag, !screenLocked, !asleep, secondsSinceInput < inputIdleThreshold else { return .idle }
        return .active
    }

    /// The heartbeat to write now, or `nil` if what's already published still holds. Active heartbeats
    /// are refreshed every `refreshInterval`; going idle is published straight away, once.
    public static func heartbeatToPublish(
        previous: DeviceHeartbeat?,
        deviceID: String,
        platform: DevicePlatform,
        activity: DeviceHeartbeat.Activity,
        now: Date
    ) -> DeviceHeartbeat? {
        switch activity {
        case .idle:
            // Nothing published means nothing to retract.
            guard let previous, previous.activity == .active else { return nil }
            return DeviceHeartbeat(deviceID: deviceID, platform: platform, activity: .idle, updatedAt: now, activeUntil: now)
        case .active:
            if let previous, previous.activity == .active,
               previous.updatedAt <= now,
               now.timeIntervalSince(previous.updatedAt) < refreshInterval,
               previous.activeUntil > now {
                return nil
            }
            return DeviceHeartbeat(
                deviceID: deviceID,
                platform: platform,
                activity: .active,
                updatedAt: now,
                activeUntil: now.addingTimeInterval(activeValidity)
            )
        }
    }

    /// The synced map after this device writes `heartbeat`: its own entry replaced, other devices kept,
    /// and anything not heard from in `pruneAfter` dropped.
    public static func merging(
        _ heartbeat: DeviceHeartbeat,
        into devices: [String: DeviceHeartbeat],
        now: Date
    ) -> [String: DeviceHeartbeat] {
        var devices = pruned(devices, now: now)
        devices[heartbeat.deviceID] = heartbeat
        return devices
    }

    public static func pruned(_ devices: [String: DeviceHeartbeat], now: Date) -> [String: DeviceHeartbeat] {
        devices.filter { now.timeIntervalSince($0.value.updatedAt) < pruneAfter }
    }
}
