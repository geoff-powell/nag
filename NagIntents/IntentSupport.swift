import AppIntents
import NagCore
import NagKit

/// Finishes a mutating intent: re-plans notifications and refreshes the always-visible surfaces.
/// The widget extension has no Family Controls entitlement, so it runs the light sync.
func finishIntent() async {
    #if NAG_WIDGET_EXTENSION
    _ = await NagEngine.syncWithoutScreenTime()
    #else
    await NagEngine.sync()
    CloudTaskSync(store: SharedStore.shared) {}.reconcile()
    #endif
}

func intentError(_ failure: NagActions.Failure) -> some Error {
    IntentFailure(message: failure.errorDescription ?? "Nag couldn't complete that action.")
}

private struct IntentFailure: LocalizedError, CustomLocalizedStringResourceConvertible {
    let message: String
    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }
}
