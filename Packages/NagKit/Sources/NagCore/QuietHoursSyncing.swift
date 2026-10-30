import Foundation

/// The quiet-hours window as it syncs between devices. Last writer wins.
public struct SyncedQuietHours: Codable, Hashable, Sendable {
    public var quietHours: QuietHours
    public var updatedAt: Date

    public init(quietHours: QuietHours, updatedAt: Date) {
        self.quietHours = quietHours
        self.updatedAt = updatedAt
    }
}

public enum QuietHoursMerge {
    /// Builds the local sync value, migrating quiet hours customised before sync was introduced.
    /// Once the returned value is applied, later reconciles retain the first migration timestamp.
    public static func localValue(for settings: AppSettings, now: Date) -> SyncedQuietHours {
        let updatedAt = settings.quietHoursUpdatedAt
            ?? (settings.quietHours == QuietHours() ? .distantPast : now)
        return SyncedQuietHours(quietHours: settings.quietHours, updatedAt: updatedAt)
    }

    /// Last writer wins; ties break deterministically so both devices converge.
    public static func merge(_ a: SyncedQuietHours, _ b: SyncedQuietHours) -> SyncedQuietHours {
        guard a.updatedAt == b.updatedAt else { return a.updatedAt > b.updatedAt ? a : b }
        return isLarger(a.quietHours, than: b.quietHours) ? a : b
    }

    private static func isLarger(_ a: QuietHours, than b: QuietHours) -> Bool {
        if a.enabled != b.enabled { return a.enabled }
        if a.startMinute != b.startMinute { return a.startMinute > b.startMinute }
        return a.endMinute > b.endMinute
    }
}

extension AppSettings {
    /// A missing stamp means this device has never edited quiet hours, so it loses to any deliberate edit.
    public var syncedQuietHours: SyncedQuietHours {
        SyncedQuietHours(quietHours: quietHours, updatedAt: quietHoursUpdatedAt ?? .distantPast)
    }

    public mutating func apply(_ synced: SyncedQuietHours) {
        quietHours = synced.quietHours
        quietHoursUpdatedAt = synced.updatedAt
    }
}
