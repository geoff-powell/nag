// A control must not be a way out of a lock (ISSUES.md:62). This intent can only engage a lock;
// an off tap performs no mutation and hands the user to Nag's guarded unlock flow.

import AppIntents
import NagCore
import WidgetKit

struct SetLockEngagedIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Lock Now"
    static let description = IntentDescription(
        "Turns a lock on. Turning a lock off always goes through Nag's unlock screen."
    )
    // Engaging a lock without shields is the unsafe direction. Foregrounding Nag triggers
    // AppModel.becameActive() → full NagEngine.sync(), which applies shields whether perform() ran
    // in the app or the widget extension.
    static let openAppWhenRun = true

    @Parameter(title: "Lock") var lock: LockEntity?
    @Parameter(title: "On") var value: Bool

    init() {}

    init(lock: LockEntity?) {
        self.lock = lock
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let lock else {
            // No lock chosen yet: change nothing and open Nag at Locks.
            ControlCenter.shared.reloadControls(ofKind: NagID.Control.lockNow)
            return .result(opensIntent: OpenURLIntent(NagRoute.locks.url))
        }
        guard value else {
            // Off never changes the lock: reload so the toggle snaps back on, and open the unlock screen.
            ControlCenter.shared.reloadControls(ofKind: NagID.Control.lockNow)
            return .result(opensIntent: OpenURLIntent(NagRoute.unlock(profileID: lock.id).url))
        }
        do {
            _ = try NagActions.lockNow(profileID: lock.id)
            await finishIntent()
            return .result(opensIntent: OpenURLIntent(NagRoute.locks.url))
        } catch let failure {
            throw intentError(failure)
        }
    }
}
