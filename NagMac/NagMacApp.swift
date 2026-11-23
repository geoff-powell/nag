import NagKit
import SwiftUI

/// The menu bar app. Started by `NagMacMain` unless Nag was launched as an MCP server.
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

    // No TimelineView here: inside a MenuBarExtra label it makes SwiftUI re-render the status item in a
    // tight loop at launch (100% CPU, gigabytes of memory, menu bar never appears). The model's tick
    // already refreshes `lastTick` every few seconds, which is all the label needs.
    var body: some View {
        let now = model.lastTick
        let due = model.dueCount(at: now)
        let locked = model.state.profiles.contains { $0.isShielding(at: now) }
        HStack(spacing: 3) {
            Image(systemName: due > 0 ? "bell.badge.fill" : locked ? "lock.fill" : "bell")
            if due > 0 { Text("\(due)") }
        }
    }
}
