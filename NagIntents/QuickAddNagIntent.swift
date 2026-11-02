import AppIntents
import NagCore

struct QuickAddNagIntent: AppIntent {
    static let title: LocalizedStringResource = "New Nag"
    static let description = IntentDescription("Opens Nag to create a new nag.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(NagRoute.newNag.url))
    }
}
