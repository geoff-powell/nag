import AppIntents
import NagCore

struct ShowUnlockStepsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Unlock Steps"
    static let description = IntentDescription("Shows what remains before a lock can be unlocked in Nag.")
    static let openAppWhenRun = false

    @Parameter(title: "Lock", requestValueDialog: "Which lock's steps do you want to see?") var lock: LockEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show unlock steps for \(\.$lock)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        do {
            let steps = try NagActions.unlockSteps(profileID: lock.id, steps: nil)
            let lines = steps.map { "\($0.isMet ? "✓" : "•") \($0.title) — \($0.detail)" }
            let unmet = steps.filter { !$0.isMet }
            let dialog: String
            if unmet.isEmpty {
                dialog = "Everything's done. Open Nag to unlock."
            } else {
                dialog = "\(unmet.count) left: \(unmet.map(\.title).joined(separator: ", "))."
            }
            return .result(value: lines, dialog: IntentDialog(stringLiteral: dialog))
        } catch let failure {
            throw intentError(failure)
        }
    }
}
