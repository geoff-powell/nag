import AppIntents
import NagCore

/// Starts a lock. There is deliberately no unlock intent: unlocking must satisfy the lock's
/// requirements in Nag. `ShowUnlockStepsIntent` reports those requirements without changing them.
struct StartLockIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Lock"
    static let description = IntentDescription("Starts a lock without providing a way to bypass its unlock requirements.")
    static let openAppWhenRun = false

    @Parameter(title: "Lock", requestValueDialog: "Which lock do you want to start?") var lock: LockEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$lock)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            _ = try NagActions.lockNow(profileID: lock.id)
            await finishIntent()
            let profile = SharedStore.shared.load().profile(lock.id)
            guard let profile else { throw intentError(.noSuchLock) }
            return .result(dialog: "“\(profile.name)” is on.")
        } catch let failure as NagActions.Failure {
            throw intentError(failure)
        }
    }
}
