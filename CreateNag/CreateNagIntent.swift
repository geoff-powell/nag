import AppIntents
import NagKit

#if os(macOS)
/// The app model the Create Nag intents add nags through.
typealias CreateNagModel = MacModel

extension MacModel {
    /// Waits until the nag's notifications are planned.
    func waitForSync() async {
        await waitForNotificationSync()
    }
}
#else
/// The app model the Create Nag intents add nags through.
typealias CreateNagModel = AppModel
#endif

/// Adds a nag from Shortcuts, Siri or Apple Intelligence, on iPhone and Mac. Shortcuts automations make
/// it the bridge for Calendar events, Notes, Reminders and any app with Shortcuts actions.
struct CreateNagIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Nag"
    static let description = IntentDescription(
        """
        Adds a nag that keeps at you until it's done. Give it a source and a source ID, such as a \
        Calendar event's identifier, and running it again updates that nag instead of adding another.
        """
    )

    // Optional so `perform()` knows when it had to ask. That's a conversation with Siri, where one more
    // question about the start is welcome. Shortcuts runs that pass a title are never asked it.
    @Parameter(title: "Title", requestValueDialog: "What should Nag nag you about?")
    var title: String?

    @Parameter(title: "Notes", requestValueDialog: "What notes should the nag include?")
    var notes: String?

    @Parameter(title: "Starts", description: "When nagging starts. Leave empty to start now.")
    var startAt: Date?

    // Left out of the parameter summary, so Shortcuts doesn't show it next to Starts.
    @Parameter(
        title: "Starts In Words",
        description: "When nagging starts, such as “8 PM”, “in 20 minutes” or “now”. Used when Starts is empty."
    )
    var spokenStart: String?

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

    @Dependency private var model: CreateNagModel

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
        let title: String
        let isConversation: Bool
        if let given = self.title {
            // A blank title from a shortcut fails as before, rather than stopping an automation to ask.
            title = given
            isConversation = false
        } else {
            title = try await $title.requestValue("What should Nag nag you about?")
            isConversation = true
        }

        let start = try await startDate(askingIfMissing: isConversation)
        let draft = try model.apply(NagRequest(
            title: title,
            notes: notes,
            startAt: start,
            repeatRule: repeatOption?.rule,
            repeatEvery: everyDays,
            monthDay: monthDay,
            preset: preset?.preset,
            intervalMinutes: intervalMinutes,
            source: source,
            externalID: externalID,
            link: link
        ))
        // Plan the notifications before the system suspends Nag again.
        await model.waitForSync()
        return .result(value: draft.task.id.uuidString, dialog: IntentDialog(stringLiteral: draft.summary))
    }

    /// Starts, or else the start in words. When neither was given in a conversation, asks once, and once
    /// more with examples if the answer isn't a time. `nil` starts now.
    @MainActor
    private func startDate(askingIfMissing ask: Bool) async throws -> Date? {
        if let startAt { return startAt }
        if let spokenStart { return try SpokenStart.date(from: spokenStart, now: .now, calendar: model.calendar) }
        guard ask else { return nil }

        let answer = try await $spokenStart.requestValue("When should I start nagging?")
        do {
            return try SpokenStart.date(from: answer, now: .now, calendar: model.calendar)
        } catch {
            let retry = try await $spokenStart.requestValue("Sorry, when? Say a time like 8 PM, in 20 minutes, or now.")
            return try SpokenStart.date(from: retry, now: .now, calendar: model.calendar)
        }
    }
}
