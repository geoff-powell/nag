import NagCore
import SwiftUI
import WidgetKit

struct NagsDueControl: ControlWidget {
    static let kind = "NagsDue"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: DueCountProvider()) { count in
            ControlWidgetButton(action: OpenNagsIntent()) {
                if count == 0 {
                    Label("All clear", systemImage: "bell")
                } else {
                    Label("\(count) due", systemImage: "bell.badge.fill")
                }
            }
        }
        .displayName("Nags Due")
        .description("Shows how many nags are due and opens the nag list.")
    }
}

struct DueCountProvider: ControlValueProvider {
    let previewValue = 3

    func currentValue() async throws -> Int {
        ControlState.make(
            from: SharedStore.shared.load(),
            lockID: nil,
            now: .now,
            calendar: .current
        ).dueCount
    }
}
