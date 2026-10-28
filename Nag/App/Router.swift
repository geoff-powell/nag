import Foundation
import Observation

/// Identifies something to present with `.sheet(item:)`.
struct PresentedID: Identifiable, Hashable {
    let id: UUID
}

/// Navigation that notifications and the shield can trigger from outside the view hierarchy.
@MainActor
@Observable
final class Router {
    enum Tab: Hashable {
        case nags
        case locks
        case settings
    }

    var tab: Tab = .nags
    /// Presents the unlock flow for a lock.
    var unlock: PresentedID?
    /// Presents the key scan that proves a nag is done.
    var proof: PresentedID?
    /// A nag to bring to attention in the list.
    var focusedTask: UUID?

    func showUnlock(_ profileID: UUID) {
        tab = .locks
        proof = nil
        unlock = PresentedID(id: profileID)
    }

    func showProof(for taskID: UUID) {
        tab = .nags
        unlock = nil
        proof = PresentedID(id: taskID)
    }

    func showTask(_ taskID: UUID) {
        tab = .nags
        focusedTask = taskID
    }
}
