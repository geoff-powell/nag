import Foundation

/// A one-tap starting point for a nag's style and completion proof.
public struct NagPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    public var summary: String
    public var style: NagStyle
    public var wantsScanProof: Bool

    public static let medication = NagPreset(
        id: "medication",
        name: "Medication",
        symbol: "pills",
        summary: "Every 5 min · 1 snooze · scan if paired",
        style: NagStyle(intervalMinutes: 5, escalation: .relentless, maxSnoozes: 1),
        wantsScanProof: true
    )

    public static let chore = NagPreset(
        id: "chore",
        name: "Chore",
        symbol: "checklist",
        summary: "Every 15 min · 3 snoozes",
        style: NagStyle(intervalMinutes: 15, escalation: .gentle, maxSnoozes: 3),
        wantsScanProof: false
    )

    public static let appointment = NagPreset(
        id: "appointment",
        name: "Appointment",
        symbol: "calendar",
        summary: "Every 10 min · no snoozes",
        style: NagStyle(intervalMinutes: 10, escalation: .relentless, maxSnoozes: 0),
        wantsScanProof: false
    )

    public static let someday = NagPreset(
        id: "someday",
        name: "Someday",
        symbol: "clock",
        summary: "Every hour · snooze any time",
        style: NagStyle(intervalMinutes: 60, escalation: .steady, maxSnoozes: nil),
        wantsScanProof: false
    )

    public static let all: [NagPreset] = [medication, chore, appointment, someday]

    /// Applies the preset to a nag in progress. Keeps the title, notes, source, link and ID.
    public func apply(to task: inout NagTask, keys: [UnlockKey], now: Date, calendar: Calendar) {
        task.style.intervalMinutes = style.intervalMinutes
        task.style.escalation = style.escalation
        task.style.maxSnoozes = style.maxSnoozes
        task.proof = wantsScanProof ? (keys.first.map { .scanKey($0.id) } ?? .none) : .none
        task.updatedAt = now
        _ = calendar
    }

    /// Whether the nag has the settings this preset applies. Medication matches any paired scan
    /// key, since the editor lets the user pick which one.
    public func matches(_ task: NagTask, keys: [UnlockKey]) -> Bool {
        let proofMatches = wantsScanProof && !keys.isEmpty ? task.proof.keyID != nil : task.proof == .none
        return proofMatches
            && task.style.intervalMinutes == style.intervalMinutes
            && task.style.escalation == style.escalation
            && task.style.maxSnoozes == style.maxSnoozes
    }

    /// The first preset the nag matches, or `nil` when its settings are custom.
    public static func matching(_ task: NagTask, keys: [UnlockKey]) -> NagPreset? {
        all.first { $0.matches(task, keys: keys) }
    }
}

/// The values the nag editors offer. Each list also includes the nag's current value, so a nag
/// created elsewhere (Shortcuts, MCP, a link) still shows what it has.
public enum NagStyleChoices {
    public static let intervals = [1, 2, 5, 10, 15, 30, 60]
    public static let snoozeLengths = [5, 10, 15, 30, 60]
    public static let workLengths = [10, 15, 25, 30, 45, 60, 90]
    /// `nil` is unlimited.
    public static let snoozeLimits: [Int?] = [0, 1, 3, 5, nil]

    public static func minutes(_ base: [Int], including current: Int) -> [Int] {
        base.contains(current) ? base : (base + [current]).sorted()
    }

    public static func snoozeLimits(including current: Int?) -> [Int?] {
        guard let current, !snoozeLimits.contains(current) else { return snoozeLimits }
        let limited = (snoozeLimits.compactMap { $0 } + [current]).sorted()
        return limited.map(Optional.some) + [nil]
    }

    public static func snoozeLimitLabel(_ limit: Int?) -> String {
        switch limit {
        case nil: "Unlimited"
        case 0: "None"
        case let n?: "\(n)"
        }
    }
}
