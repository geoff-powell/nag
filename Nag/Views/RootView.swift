import NagKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Nags", systemImage: "bell.badge.fill", value: Router.Tab.nags) {
                NagListView()
            }
            .badge(model.outstandingCount)

            Tab("Locks", systemImage: "lock.fill", value: Router.Tab.locks) {
                LockListView()
            }

            Tab("Settings", systemImage: "gearshape.fill", value: Router.Tab.settings) {
                SettingsView()
            }
        }
        .tint(.orange)
        .sheet(item: $router.unlock) { item in
            UnlockView(profileID: item.id)
        }
        .sheet(item: $router.proof) { item in
            TaskProofSheet(taskID: item.id)
        }
        .sheet(item: $router.incoming) { item in
            TaskEditorView(draft: item.draft)
        }
        .alert("Couldn't add that nag", isPresented: hasLinkError) {
            Button("OK") { router.linkError = nil }
        } message: {
            Text(router.linkError ?? "")
        }
        .fullScreenCover(isPresented: needsOnboarding) {
            OnboardingView()
        }
    }

    private var hasLinkError: Binding<Bool> {
        Binding(
            get: { router.linkError != nil },
            set: { if !$0 { router.linkError = nil } }
        )
    }

    private var needsOnboarding: Binding<Bool> {
        Binding(
            get: { !model.state.settings.hasOnboarded },
            set: { _ in }
        )
    }
}
