import AppIntents
import NagCore

struct ScanProofIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan To Complete Nag"
    static let description = IntentDescription("Opens Nag's key scanner to prove a nag is complete.")
    static let openAppWhenRun = true

    @Parameter(title: "Nag", requestValueDialog: "Which nag needs a key scan?") var nag: NagEntity

    init() {}

    init(nag: NagEntity) {
        self.nag = nag
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Scan to complete \(\.$nag)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentNavigation.open(.scan(taskID: nag.id))
        return .result()
    }
}
