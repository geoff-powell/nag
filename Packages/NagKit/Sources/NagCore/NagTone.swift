/// How direct the wording of nag notifications should be.
public enum NagTone: String, Codable, CaseIterable, Sendable {
    case gentle
    case standard
    case pushy

    public var label: String {
        switch self {
        case .gentle: "Gentle"
        case .standard: "Standard"
        case .pushy: "Pushy"
        }
    }

    public var explanation: String {
        switch self {
        case .gentle: "Warm encouragement without guilt or pressure."
        case .standard: "The usual reminders, getting firmer over time."
        case .pushy: "Blunt reminders that press you to act now."
        }
    }
}
