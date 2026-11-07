import AppIntents
import NagKit

enum NagRepeatOption: String, AppEnum {
    case never
    case daily
    case weekdays
    case weekly
    case everyNDays
    case monthly

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Repeat"
    static let caseDisplayRepresentations: [NagRepeatOption: DisplayRepresentation] = [
        .never: "Once",
        .daily: "Every day",
        .weekdays: "Weekdays",
        .weekly: "Every week",
        .everyNDays: "Every N days",
        .monthly: "Every month",
    ]

    var rule: RepeatRule {
        switch self {
        case .never: .never
        case .daily: .daily
        case .weekdays: .weekdays
        case .weekly: .weekly
        case .everyNDays: .everyNDays
        case .monthly: .monthly
        }
    }
}

/// `NagPreset.all`, for Shortcuts and for App Shortcut phrases such as "Add a medication nag in Nag".
/// Raw values are the presets' IDs.
enum NagPresetOption: String, AppEnum {
    case medication
    case chore
    case appointment
    case someday

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let caseDisplayRepresentations: [NagPresetOption: DisplayRepresentation] = [
        .medication: DisplayRepresentation(
            title: "Medication",
            subtitle: "Every 5 min · relentless · 1 snooze · scan if available",
            image: .init(systemName: "pills"),
            synonyms: ["Meds", "Medicine", "Pill", "Pills"]
        ),
        .chore: DisplayRepresentation(
            title: "Chore",
            subtitle: "Every 15 min · gentle · 3 snoozes",
            image: .init(systemName: "checklist"),
            synonyms: ["Chores", "Task", "Housework"]
        ),
        .appointment: DisplayRepresentation(
            title: "Appointment",
            subtitle: "Every 10 min · relentless · no snoozes",
            image: .init(systemName: "calendar"),
            synonyms: ["Appointments", "Meeting"]
        ),
        .someday: DisplayRepresentation(
            title: "Someday",
            subtitle: "Every 60 min · steady · unlimited snoozes",
            image: .init(systemName: "clock"),
            synonyms: ["Sometime", "Low priority"]
        ),
    ]

    var preset: NagPreset { NagPreset.all.first { $0.id == rawValue } ?? .chore }
}

extension NagDraft {
    /// "Added “Call mum”, starting now." for Siri and Shortcuts to say.
    var summary: String {
        let verb = isNew ? "Added" : "Updated"
        let start = task.startAt <= .now.addingTimeInterval(60)
            ? "starting now"
            : "starting \(task.startAt.formatted(date: .abbreviated, time: .shortened))"
        return "\(verb) “\(task.title)”, \(start)."
    }
}

// Siri and Shortcuts show an error's `localizedStringResource`. Without it they say the operation
// couldn't be completed, instead of what was wrong with the request.
extension NagRequestError: @retroactive CustomLocalizedStringResourceConvertible {
    public var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "Nag couldn't add that nag.")
    }
}
