import AppIntents
import NagCore
#if !NAG_WIDGET_EXTENSION
import UIKit
#endif

struct CompleteNagIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Nag"
    static let description = IntentDescription(
        "Marks a nag done. Nags that need a key scan must be scanned in Nag."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Nag", requestValueDialog: "Which nag did you complete?") var nag: NagEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$nag) done")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let task = try NagActions.complete(taskID: nag.id)
            await finishIntent()
            return .result(dialog: "Done: “\(task.title)”.")
        } catch NagActions.Failure.needsKeyScan(let taskID, let keyName) {
            // Never complete a key-scan nag here. In the app, offer to continue at the scan sheet.
            #if NAG_WIDGET_EXTENSION
            throw intentError(.needsKeyScan(taskID: taskID, keyName: keyName))
            #else
            let url = NagRoute.scan(taskID: taskID).url
            throw needsToContinueInForegroundError(
                "Scan “\(keyName)” in Nag to complete this nag.",
                continuation: { _ = await UIApplication.shared.open(url) }
            )
            #endif
        } catch let failure {
            throw intentError(failure)
        }
    }
}

#if !NAG_WIDGET_EXTENSION
extension CompleteNagIntent: ForegroundContinuableIntent {}
#endif
