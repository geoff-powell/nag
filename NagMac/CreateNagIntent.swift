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

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "Starts", description: "When nagging starts. Leave empty to start now.")
    var startAt: Date?

    @Parameter(title: "Repeat", description: "Leave empty for a one-off nag.")
    var repeatOption: NagRepeatOption?

    @Parameter(title: "Nag Every", description: "Minutes between nags, from 1 to 1440.")
    var intervalMinutes: Int?

    @Parameter(title: "Source", description: "Where this came from, such as Calendar, Notes or Muse. Shown on the nag.")
    var source: String?

    @Parameter(title: "Source ID", description: "The source's ID for the item. The same source and ID again updates the nag.")
    var externalID: String?

    @Parameter(title: "Link", description: "Opens the original item from the nag.")
    var link: URL?

    @Dependency private var model: MacModel

    static var parameterSummary: some ParameterSummary {
        Summary("Nag me about \(\.$title)") {
            \.$startAt
            \.$repeatOption
            \.$notes
            \.$intervalMinutes
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
            intervalMinutes: intervalMinutes,
            source: source,
            externalID: externalID,
            link: link
        ))
        // Plan the notifications before reporting back.
        await model.waitForNotificationSync()
        return .result(value: draft.task.id.uuidString, dialog: IntentDialog(stringLiteral: draft.summary))
    }
}

enum NagRepeatOption: String, AppEnum {
    case never
    case daily
    case weekdays
    case weekly

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Repeat"
    static let caseDisplayRepresentations: [NagRepeatOption: DisplayRepresentation] = [
        .never: "Once",
        .daily: "Every day",
        .weekdays: "Weekdays",
        .weekly: "Every week",
    ]

    var rule: RepeatRule {
        switch self {
        case .never: .never
        case .daily: .daily
        case .weekdays: .weekdays
        case .weekly: .weekly
        }
    }
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
