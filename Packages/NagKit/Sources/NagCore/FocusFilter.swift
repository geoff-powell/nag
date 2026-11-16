import Foundation

/// Minimum nag urgency allowed through while a Focus filter is active.
public enum FocusUrgency: String, Codable, CaseIterable, Comparable, Sendable {
    case all
    case gentle
    case relentless

    public static let systemFilterCriteria = "system"

    public var label: String {
        switch self {
        case .all: "All nags"
        case .gentle: "Gentle and relentless"
        case .relentless: "Relentless only"
        }
    }

    public var subtitle: String {
        switch self {
        case .all: "Deliver every nag as usual"
        case .gentle: "Quiet steady nags such as Someday"
        case .relentless: "Only urgent nags such as Medication and Appointment"
        }
    }

    private var rank: Int {
        switch self {
        case .all: 0
        case .gentle: 1
        case .relentless: 2
        }
    }

    public static func < (lhs: FocusUrgency, rhs: FocusUrgency) -> Bool {
        lhs.rank < rhs.rank
    }

    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = FocusUrgency(rawValue: rawValue) ?? .all
    }

    public func allows(_ style: NagStyle) -> Bool {
        switch self {
        case .all:
            true
        case .gentle:
            style.breakThroughFocus && (style.escalation == .gentle || style.escalation == .relentless)
        case .relentless:
            style.breakThroughFocus && style.escalation == .relentless
        }
    }

    public static func filterCriteria(for style: NagStyle) -> String {
        guard style.breakThroughFocus else { return "focus-off" }
        return style.escalation.rawValue
    }
}

/// Active Focus filter state on this device. Lives in `AppSettings` and never syncs across devices,
/// because each device can be in its own Focus or have different local locks.
public struct FocusFilter: Codable, Hashable, Sendable {
    /// Lock profiles the active Focus wants on, mapped to when Focus began asking for each one.
    public var lockStarts: [UUID: Date]
    public var minimumUrgency: FocusUrgency
    /// Switches quiet hours on while the Focus is active, leaving the user's saved schedule intact.
    public var quietHours: Bool

    public init(
        lockStarts: [UUID: Date] = [:],
        minimumUrgency: FocusUrgency = .all,
        quietHours: Bool = false
    ) {
        self.lockStarts = lockStarts
        self.minimumUrgency = minimumUrgency
        self.quietHours = quietHours
    }

    private enum CodingKeys: String, CodingKey {
        case lockStarts, minimumUrgency, quietHours
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawStarts = try c.decodeIfPresent([String: Date].self, forKey: .lockStarts) ?? [:]
        var parsed: [UUID: Date] = [:]
        parsed.reserveCapacity(rawStarts.count)
        for (key, date) in rawStarts {
            if let id = UUID(uuidString: key) {
                parsed[id] = date
            }
        }
        lockStarts = parsed
        minimumUrgency = try c.decodeIfPresent(FocusUrgency.self, forKey: .minimumUrgency) ?? .all
        quietHours = try c.decodeIfPresent(Bool.self, forKey: .quietHours) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let rawStarts = Dictionary(uniqueKeysWithValues: lockStarts.map { ($0.key.uuidString, $0.value) })
        try c.encode(rawStarts, forKey: .lockStarts)
        try c.encode(minimumUrgency, forKey: .minimumUrgency)
        try c.encode(quietHours, forKey: .quietHours)
    }

    public var lockIDs: Set<UUID> {
        Set(lockStarts.keys)
    }

    public var isActive: Bool {
        !lockStarts.isEmpty || minimumUrgency != .all || quietHours
    }

    public func allows(_ style: NagStyle) -> Bool {
        !quietHours && minimumUrgency.allows(style)
    }

    /// Notification `filterCriteria` values allowed in Notification Center while this filter is on,
    /// or `nil` when no extra notification predicate should be applied.
    public var allowedNotificationCriteria: [String]? {
        if quietHours {
            return [FocusUrgency.systemFilterCriteria]
        }
        switch minimumUrgency {
        case .all:
            return nil
        case .gentle:
            return [Escalation.gentle.rawValue, Escalation.relentless.rawValue, FocusUrgency.systemFilterCriteria]
        case .relentless:
            return [Escalation.relentless.rawValue, FocusUrgency.systemFilterCriteria]
        }
    }

    public var notificationFilterPredicate: NSPredicate? {
        allowedNotificationCriteria.map { NSPredicate(format: "SELF IN %@", $0) }
    }

    /// Produces the next Focus filter state, keeping the original start date of any lock that stays
    /// selected so an unlock earned mid-Focus sticks across edits or Focus transitions.
    public func updated(
        lockIDs: Set<UUID>,
        minimumUrgency: FocusUrgency,
        quietHours: Bool,
        now: Date
    ) -> FocusFilter {
        var nextStarts: [UUID: Date] = [:]
        nextStarts.reserveCapacity(lockIDs.count)
        for id in lockIDs {
            nextStarts[id] = lockStarts[id] ?? now
        }
        return FocusFilter(
            lockStarts: nextStarts,
            minimumUrgency: minimumUrgency,
            quietHours: quietHours
        )
    }
}

/// Title and subtitle shown on the Focus Filter card in Settings.
public struct FocusFilterSummary: Hashable, Sendable {
    public var title: String
    public var subtitle: String

    public static func make(
        lockNames: [String],
        minimumUrgency: FocusUrgency,
        quietHours: Bool
    ) -> FocusFilterSummary {
        let nagSummary = if quietHours {
            "Quiet hours on"
        } else {
            switch minimumUrgency {
            case .all: "All nags"
            case .gentle: "Gentle and relentless nags"
            case .relentless: "Relentless nags only"
            }
        }

        if !lockNames.isEmpty {
            let joined = lockNames.joined(separator: ", ")
            return FocusFilterSummary(title: "Lock \(joined)", subtitle: nagSummary)
        }
        if quietHours {
            return FocusFilterSummary(title: "Quiet hours on", subtitle: "All nags paused")
        }
        if minimumUrgency != .all {
            return FocusFilterSummary(title: nagSummary, subtitle: "No locks")
        }
        return FocusFilterSummary(title: "No changes", subtitle: "All nags, no locks")
    }
}

extension AppSettings {
    public func isQuietHoursActive(at date: Date, calendar: Calendar) -> Bool {
        focusFilter.quietHours || quietHours.contains(date, calendar: calendar)
    }
}

extension NagState {
    /// Applies a Focus filter (or clears it when Focus ends) and brings every lock up to date.
    /// Returns any locks that automatically unlocked during maintenance.
    @discardableResult
    public mutating func applyFocusFilter(
        lockIDs: Set<UUID> = [],
        minimumUrgency: FocusUrgency = .all,
        quietHours: Bool = false,
        now: Date,
        calendar: Calendar
    ) -> [LockProfile] {
        let knownIDs = Set(profiles.map(\.id))
        settings.focusFilter = settings.focusFilter.updated(
            lockIDs: lockIDs.intersection(knownIDs),
            minimumUrgency: minimumUrgency,
            quietHours: quietHours,
            now: now
        )
        return LockMaintenance.run(&self, now: now, calendar: calendar)
    }
}
