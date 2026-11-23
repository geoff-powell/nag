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

/// Where an `openAppWhenRun` intent sends Nag once it's open.
///
/// These intents run in the app process. Returning `OpenURLIntent` with a `nag://` link from
/// there doesn't navigate: on iOS 27 the system drops the URL. So the app hands the route straight
/// to its router. The widget extension never sets `handler`, so the call does nothing there.
@MainActor
enum IntentNavigation {
    static var handler: ((NagRoute) -> Void)?

    static func open(_ route: NagRoute) {
        handler?(route)
    }
}

// Returns `any Error`, not `some Error`: throwing an opaque error from the async intents crashes
// the Swift compiler (6.3, 6.4) in optimized builds.
func intentError(_ failure: NagActions.Failure) -> any Error {
    IntentFailure(message: failure.errorDescription ?? "Nag couldn't complete that action.")
}

private struct IntentFailure: LocalizedError, CustomLocalizedStringResourceConvertible {
    let message: String
    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }
}
