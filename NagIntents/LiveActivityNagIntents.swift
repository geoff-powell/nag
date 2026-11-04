import AppIntents
import NagCore
#if !NAG_WIDGET_EXTENSION
import NagKit
#endif

/// Activity-only completion intent. `LiveActivityIntent` guarantees execution in the app process.
struct CompleteNagFromActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete Nag from Live Activity"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Nag") var nag: NagEntity

    init() {}

    init(nag: NagEntity) {
        self.nag = nag
    }

    func perform() async throws -> some IntentResult {
        do {
            try NagActions.complete(taskID: nag.id)
            await finishIntent()
            await reconcileLiveActivitiesAfterIntent()
            return .result()
        } catch let failure {
            // NagActions refuses key-scan completion, including stale activity button invocations.
            throw intentError(failure)
        }
    }
}

/// Activity-only snooze intent. Home Screen widgets continue using `SnoozeNagIntent`.
struct SnoozeNagFromActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Snooze Nag from Live Activity"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Nag") var nag: NagEntity
    @Parameter(title: "Length") var length: SnoozeLengthOption?

    init() {}

    init(nag: NagEntity, length: SnoozeLengthOption? = nil) {
        self.nag = nag
        self.length = length
    }

    func perform() async throws -> some IntentResult {
        do {
            try NagActions.snooze(taskID: nag.id, minutes: length?.option.minutes)
            await finishIntent()
            await reconcileLiveActivitiesAfterIntent()
            return .result()
        } catch let failure {
            throw intentError(failure)
        }
    }
}

private func reconcileLiveActivitiesAfterIntent() async {
    #if !NAG_WIDGET_EXTENSION
    let state = SharedStore.shared.load()
    // `reconcile` checks the user's opt-in before starting or updating anything.
    await LiveActivities.reconcile(state: state, now: .now, calendar: .current)
    #endif
}
