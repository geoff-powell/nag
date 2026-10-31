import AppIntents
import NagCore

struct ScanProofIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan To Complete Nag"
    static let description = IntentDescription("Opens Nag's key scanner to prove a nag is complete.")
    static let openAppWhenRun = true

    @Parameter(title: "Nag", requestValueDialog: "Which nag needs a key scan?") var nag: NagEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Scan to complete \(\.$nag)")
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(NagRoute.scan(taskID: nag.id).url))
    }
}
