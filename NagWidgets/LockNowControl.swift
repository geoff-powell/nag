import NagCore
import SwiftUI
import WidgetKit

struct LockNowControl: ControlWidget {
    static let kind = NagID.Control.lockNow

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: LockEngagedProvider()) { value in
            if let lock = value.lock {
                ControlWidgetToggle(
                    isOn: value.isLockEngaged,
                    action: SetLockEngagedIntent(lock: LockEntity(lock))
                ) {
                    Label(lock.name, systemImage: lock.symbol)
                }
            } else {
                ControlWidgetButton(action: OpenNagsIntent()) {
                    Label("Choose a lock", systemImage: "lock.slash")
                }
            }
        }
        .displayName("Lock Now")
        .description("Turns a lock on. Turning it off opens Nag's unlock screen.")
    }
}

struct LockEngagedProvider: AppIntentControlValueProvider {
    typealias Configuration = LockConfiguration

    var previewValue: ControlState {
        ControlState(
            dueCount: 0,
            lock: LockSummary(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Focus",
                symbol: "lock.fill",
                isShielding: true,
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
