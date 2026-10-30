import Foundation
import NagKit
import Observation

/// Identifies something to present with `.sheet(item:)`.
struct PresentedID: Identifiable, Hashable {
    let id: UUID
}

/// A nag from a `nag://add` link, waiting in the editor for the user to save it.
struct IncomingDraft: Identifiable {
    let id = UUID()
    let draft: NagDraft
}

/// Navigation that notifications, the shield and links can trigger from outside the view hierarchy.
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
    /// A nag from a link, shown in the editor so nothing is added without the user seeing it.
    var incoming: IncomingDraft?
    /// Why the last link couldn't be opened.
    var linkError: String?

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

    /// Opens the editor on what a `nag://add` link describes.
    func open(_ url: URL, model: AppModel) {
        guard NagRequest.isNagURL(url) else { return }
        do {
            let request = try NagRequest(url: url, now: .now, calendar: model.calendar)
            let draft = try model.draft(for: request)
            tab = .nags
            unlock = nil
            proof = nil
            incoming = IncomingDraft(draft: draft)
        } catch {
            linkError = error.localizedDescription
        }
    }
}
