import AppIntents
import NagCore

/// Opens Nag's guarded unlock flow without changing the lock's state.
struct OpenUnlockIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Unlock"
    static let description = IntentDescription("Opens Nag's guarded unlock flow for a lock.")
    static let openAppWhenRun = true

    @Parameter(title: "Lock", requestValueDialog: "Which lock do you want to unlock?") var lock: LockEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open unlock steps for \(\.$lock)")
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(NagRoute.unlock(profileID: lock.id).url))
    }
}
