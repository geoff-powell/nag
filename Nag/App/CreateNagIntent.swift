import AppIntents
import NagKit

/// Adds a nag from Shortcuts, Siri or Apple Intelligence. Shortcuts automations make it the bridge for
/// Calendar events, Notes, Reminders and any app with Shortcuts actions.
struct CreateNagIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Nag"
    static let description = IntentDescription(
        """
        Adds a nag that keeps at you until it's done. Give it a source and a source ID, such as a \
        Calendar event's identifier, and running it again updates that nag instead of adding another.
        """
    )

    @Parameter(title: "Title", requestValueDialog: "What should Nag nag you about?")
    var title: String

    @Parameter(title: "Notes", requestValueDialog: "What notes should the nag include?")
    var notes: String?

    @Parameter(title: "Starts", description: "When nagging starts. Leave empty to start now.")
    var startAt: Date?

    @Parameter(title: "Repeat", description: "Leave empty for a one-off nag.")
    var repeatOption: NagRepeatOption?

    @Parameter(title: "Every N Days", description: "Used when Repeat is “Every N days”.")
    var everyDays: Int?

    @Parameter(title: "Day Of Month", description: "1–31. Used when Repeat is “Every month”.")
    var monthDay: Int?

    @Parameter(title: "Nag Every", description: "Minutes between nags, from 1 to 1440.")
    var intervalMinutes: Int?

    @Parameter(title: "Preset", description: "Starting point for how hard this nag pushes.")
    var preset: NagPresetOption?

    @Parameter(title: "Source", description: "Where this came from, such as Calendar, Notes or Muse. Shown on the nag.")
    var source: String?

    @Parameter(title: "Source ID", description: "The source's ID for the item. The same source and ID again updates the nag.")
    var externalID: String?

    @Parameter(title: "Link", description: "Opens the original item from the nag.")
    var link: URL?

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Nag me about \(\.$title)") {
            \.$startAt
            \.$repeatOption
            \.$everyDays
            \.$monthDay
            \.$notes
            \.$intervalMinutes
            \.$preset
            \.$source
            \.$externalID
            \.$link
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let draft = try model.apply(NagRequest(
            title: title,
            notes: notes,
            startAt: startAt,
            repeatRule: repeatOption?.rule,
            repeatEvery: everyDays,
            monthDay: monthDay,
            intervalMinutes: intervalMinutes,
            source: source,
            externalID: externalID,
            link: link
        ), preset: preset?.preset)
        // Plan the notifications before iOS suspends Nag again.
        await model.waitForSync()
        return .result(value: draft.task.id.uuidString, dialog: IntentDialog(stringLiteral: draft.summary))
    }
}

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

enum NagPresetOption: String, AppEnum {
    case medication
    case chore
    case appointment
    case someday

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let caseDisplayRepresentations: [NagPresetOption: DisplayRepresentation] = [
        .medication: DisplayRepresentation(title: "Medication", subtitle: "Every 5 min · relentless · 1 snooze · scan if available"),
        .chore: DisplayRepresentation(title: "Chore", subtitle: "Every 15 min · gentle · 3 snoozes"),
        .appointment: DisplayRepresentation(title: "Appointment", subtitle: "Every 10 min · relentless · no snoozes"),
        .someday: DisplayRepresentation(title: "Someday", subtitle: "Every 60 min · steady · unlimited snoozes"),
    ]

    var preset: NagPreset { NagPreset.all.first { $0.id == rawValue } ?? .chore }
}

struct NagShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNagIntent(),
            phrases: [
                "Nag me with \(.applicationName)",
                "Add a nag in \(.applicationName)",
                "Create a nag in \(.applicationName)",
            ],
            shortTitle: "Create Nag",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: CompleteNagIntent(),
            phrases: [
                "Mark a nag done in \(.applicationName)",
                "I did it \(.applicationName)",
            ],
            shortTitle: "Complete Nag",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: SnoozeNagIntent(),
            phrases: ["Snooze a nag in \(.applicationName)"],
            shortTitle: "Snooze Nag",
            systemImageName: "zzz"
        )
        AppShortcut(
            intent: StartLockIntent(),
            phrases: [
                "Lock my apps with \(.applicationName)",
                "Start a lock in \(.applicationName)",
            ],
            shortTitle: "Start Lock",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: ShowUnlockStepsIntent(),
            phrases: [
                "What do I owe \(.applicationName)",
                "Show my unlock steps in \(.applicationName)",
            ],
            shortTitle: "Unlock Steps",
            systemImageName: "list.bullet"
        )
    }
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
