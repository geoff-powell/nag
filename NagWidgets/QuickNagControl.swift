import SwiftUI
import WidgetKit

struct QuickNagControl: ControlWidget {
    static let kind = "QuickNag"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: QuickAddNagIntent()) {
                Label("Quick nag", systemImage: "bell.badge")
            }
        }
        .displayName("Quick Nag")
        .description("Opens Nag with an empty new nag.")
    }
}
