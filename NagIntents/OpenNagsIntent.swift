import AppIntents
import NagCore

struct OpenNagsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Nags"
    static let description = IntentDescription("Opens the list of nags.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentNavigation.open(.nags)
        return .result()
    }
}
