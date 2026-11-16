import NagCore
import SwiftUI
import WidgetKit

struct LockNowControl: ControlWidget {
    static let kind = NagID.Control.lockNow

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: LockEngagedProvider()) { value in
            // The template builder doesn't allow branches, so an unconfigured control is the same
            // toggle with no lock: tapping it opens Nag at Locks and changes nothing.
            ControlWidgetToggle(
                isOn: value.isLockEngaged,
                action: SetLockEngagedIntent(lock: value.lock.map(LockEntity.init))
            ) {
                Label(value.lock?.name ?? "Choose a lock", systemImage: value.lock?.symbol ?? "lock.slash")
            }
        }
        .displayName("Lock Now")
        .description("Turns a lock on. Turning it off opens Nag's unlock screen.")
    }
}

struct LockEngagedProvider: AppIntentControlValueProvider {
    typealias Configuration = LockConfiguration

    func previewValue(configuration: LockConfiguration) -> ControlState {
        ControlState.preview(
            dueCount: 0,
            lock: LockSummary(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Focus",
                symbol: "lock.fill",
                isShielding: true,
                isLockEngaged: true,
                openUntil: nil,
                waitEndsAt: nil,
                stepsRemaining: 0
            ),
            isLockEngaged: true
        )
    }

    func currentValue(configuration: LockConfiguration) async throws -> ControlState {
        ControlState.make(
            from: SharedStore.shared.load(),
            lockID: configuration.lock?.id,
            now: .now,
            calendar: .current
        )
    }
}

private extension LockEntity {
    init(_ summary: LockSummary) {
        id = summary.id
        name = summary.name
        symbol = summary.symbol
        isEngaged = summary.isLockEngaged
        isShielding = summary.isShielding
    }
}
