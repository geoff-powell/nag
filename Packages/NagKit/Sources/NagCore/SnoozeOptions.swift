/// Fixed snooze lengths offered everywhere. Global, not per nag.
public enum SnoozeOption: Int, CaseIterable, Sendable {
    case short = 5
    case medium = 15
    case long = 60

    public var minutes: Int { rawValue }
    public var label: String { NagFormat.minutes(minutes) }
    public var actionIdentifier: String { "SNOOZE_\(rawValue)" }

    public static func option(forAction id: String) -> SnoozeOption? {
        allCases.first { $0.actionIdentifier == id }
    }
}
