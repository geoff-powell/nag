import CloudKit
import UIKit

/// Exists to receive accepted CloudKit share invitations, which go to the scene delegate in a
/// scene-based app. SwiftUI still owns the window.
@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Launched by tapping an invitation.
        if let metadata = connectionOptions.cloudKitShareMetadata {
            AppDelegate.current?.acceptShare(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        AppDelegate.current?.acceptShare(cloudKitShareMetadata)
    }
}
