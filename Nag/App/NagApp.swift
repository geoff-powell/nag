import BackgroundTasks
import NagKit
import SwiftUI

@main
struct NagApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.model)
                .environment(appDelegate.router)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: appDelegate.model.becameActive()
            case .background: BackgroundRefresh.schedule()
            default: break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.schedule()
            await NagEngine.sync()
        }
    }
}

/// Background app refresh is opportunistic (iOS decides when), so it's a backstop. Repeating notifications
/// and DeviceActivity wake-ups do the real work.
enum BackgroundRefresh {
    static let identifier = (Bundle.main.bundleIdentifier ?? "nag") + ".refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
