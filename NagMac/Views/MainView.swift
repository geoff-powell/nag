import NagKit
import SwiftUI

struct MainView: View {
    @Environment(MacModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Label("Nags", systemImage: "bell.badge.fill").tag(MacModel.Section.nags)
                Label("Locks", systemImage: "lock.fill").tag(MacModel.Section.locks)
                Label("Settings", systemImage: "gearshape").tag(MacModel.Section.settings)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch model.section {
            case .nags: MacNagsView()
            case .locks: MacLocksView()
            case .settings: MacSettingsView()
            }
        }
        .tint(.orange)
        .sheet(item: $model.unlockRequest) { item in
            MacUnlockView(profileID: item.id)
        }
    }
}
