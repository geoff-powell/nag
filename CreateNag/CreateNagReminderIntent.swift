import AppIntents
import NagKit

/// Lets Apple Intelligence Siri make a nag from one sentence, such as "Nag me to take my meds at 8": it
/// fills in the title, the start and any repeat. It follows the system's Create Reminder schema, the
/// closest one to a nag, which arrived in iOS 27 and macOS 27. Earlier systems use `CreateNagIntent`.
///
/// It's assistant-only, so Shortcuts still shows a single Create Nag action. The schema's list, section,
/// tags, flag and images have no counterpart in Nag and are ignored.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .reminders.createReminder)
struct CreateNagReminderIntent {
    static let isAssistantOnly = true

    var title: String
    var list: NagListEntity?
    var note: AttributedString?
    var isFlagged: Bool?
    var images: [IntentFile]
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var locationTrigger: NagPlaceTriggerEntity?
    var section: NagSectionEntity?

    @Parameter(title: "Preset", description: "Starting point for how hard this nag pushes.")
    var preset: NagPresetOption?

    @Dependency private var model: CreateNagModel

    @MainActor
    func perform() async throws -> some ReturnsValue<NagReminderEntity> & ProvidesDialog {
        guard locationTrigger == nil else { throw CreateNagFailure.placesUnsupported }
        let now = Date.now
        let calendar = model.calendar

        var request = NagRequest(
            title: title,
            notes: note.map { String($0.characters) },
            startAt: try dueDate.map { try SpokenStart.date(from: $0, repeating: recurrence, now: now, calendar: calendar) },
            preset: preset?.preset,
            link: urls.first
        )
        if let recurrence {
            try request.setRepeat(recurrence, now: now, calendar: calendar)
        }
        let draft = try model.apply(request)
        // Plan the notifications before the system suspends Nag again.
        await model.waitForSync()
        return .result(
            value: NagReminderEntity(draft.task, calendar: calendar),
            dialog: IntentDialog(stringLiteral: draft.summary)
        )
    }
}

enum CreateNagFailure: Error, CustomLocalizedStringResourceConvertible {
    case placesUnsupported

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .placesUnsupported: "Nag can't start a nag at a place yet. Give it a time instead."
        }
    }
}
