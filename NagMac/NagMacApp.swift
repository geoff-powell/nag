import NagKit
import SwiftUI

@main
struct NagMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let model: MacModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let due = model.dueCount(at: context.date)
            let locked = model.state.profiles.contains { $0.isShielding(at: context.date) }
            HStack(spacing: 3) {
                Image(systemName: due > 0 ? "bell.badge.fill" : locked ? "lock.fill" : "bell")
                if due > 0 { Text("\(due)") }
            }
        }
    }
}
