import AppIntents
import NagCore

enum SnoozeLengthOption: Int, AppEnum {
    case short = 5
    case medium = 15
    case long = 60

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Snooze Length"
    static let caseDisplayRepresentations: [SnoozeLengthOption: DisplayRepresentation] = [
        // App Intents metadata requires literals; these mirror SnoozeOption.label.
        .short: "5 min",
        .medium: "15 min",
        .long: "1 hr",
    ]

    var option: SnoozeOption { SnoozeOption(rawValue: rawValue)! }
}

struct SnoozeNagIntent: AppIntent {
    static let title: LocalizedStringResource = "Snooze Nag"
    static let description = IntentDescription("Pauses an outstanding nag for a chosen length of time.")
    static let openAppWhenRun = false

    @Parameter(title: "Nag", requestValueDialog: "Which nag do you want to snooze?") var nag: NagEntity
    @Parameter(title: "Length") var length: SnoozeLengthOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Snooze \(\.$nag)") {
            \.$length
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let task = try NagActions.snooze(taskID: nag.id, minutes: length?.option.minutes)
            await finishIntent()
            return .result(dialog: "Snoozed “\(task.title)”.")
        } catch let failure {
            throw intentError(failure)
        }
    }
}
