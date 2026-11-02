import AppIntents
import NagCore

struct StartNagIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Nag"
    static let description = IntentDescription("Starts an outstanding nag's focused work period.")
    static let openAppWhenRun = false

    @Parameter(title: "Nag", requestValueDialog: "Which nag do you want to start?") var nag: NagEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$nag)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let task = try NagActions.start(taskID: nag.id)
            await finishIntent()
            return .result(
                dialog: "Started “\(task.title)”. I'll check back in \(NagFormat.minutes(task.style.workMinutes))."
            )
        } catch let failure {
            throw intentError(failure)
        }
    }
}
