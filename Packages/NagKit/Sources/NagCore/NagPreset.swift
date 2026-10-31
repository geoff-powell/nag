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
        summary: "Every 5 min · relentless · 1 snooze · scan if available",
        style: NagStyle(intervalMinutes: 5, escalation: .relentless, maxSnoozes: 1),
        wantsScanProof: true
    )

    public static let chore = NagPreset(
        id: "chore",
        name: "Chore",
        symbol: "checklist",
        summary: "Every 15 min · gentle · 3 snoozes",
        style: NagStyle(intervalMinutes: 15, escalation: .gentle, maxSnoozes: 3),
        wantsScanProof: false
    )

    public static let appointment = NagPreset(
        id: "appointment",
        name: "Appointment",
        symbol: "calendar",
        summary: "Every 10 min · relentless · no snoozes",
        style: NagStyle(intervalMinutes: 10, escalation: .relentless, maxSnoozes: 0),
        wantsScanProof: false
    )

    public static let someday = NagPreset(
        id: "someday",
        name: "Someday",
        symbol: "clock",
        summary: "Every 60 min · steady · unlimited snoozes",
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
}
