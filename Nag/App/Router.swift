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
    /// Presents an empty editor for a new nag.
    var newNag = false
    /// Why the last link couldn't be opened.
    var linkError: String?

    func resetPresentation() {
        unlock = nil
        proof = nil
        incoming = nil
        newNag = false
    }

    func showUnlock(_ profileID: UUID) {
        resetPresentation()
        tab = .locks
        unlock = PresentedID(id: profileID)
    }

    func showProof(for taskID: UUID) {
        resetPresentation()
        tab = .nags
        proof = PresentedID(id: taskID)
    }

    func showTask(_ taskID: UUID) {
        resetPresentation()
        tab = .nags
        focusedTask = taskID
    }

    func showNewNag() {
        resetPresentation()
        tab = .nags
        newNag = true
    }

    /// Opens the editor on what a `nag://add` link describes.
    func open(_ url: URL, model: AppModel) {
        guard NagRequest.isNagURL(url) else { return }
        do {
            let route = try NagRoute(url: url, now: .now, calendar: model.calendar)
            resetPresentation()
            switch route {
            case .add(let request):
                let draft = try model.draft(for: request)
                resetPresentation()
                tab = .nags
                incoming = IncomingDraft(draft: draft)
            case .newNag: showNewNag()
            case .nags:
                resetPresentation()
                tab = .nags
            case .nag(let id):
                guard model.state.task(id) != nil else { throw LinkError.missingNag }
                showTask(id)
            case .scan(let taskID):
                guard let task = model.state.task(taskID), model.proofKey(for: task) != nil else {
                    throw LinkError.missingScannableNag
                }
                showProof(for: taskID)
            case .unlock(let profileID):
                guard model.profile(profileID) != nil else { throw LinkError.missingLock }
                showUnlock(profileID)
            }
        } catch {
            linkError = error.localizedDescription
        }
    }

    private enum LinkError: LocalizedError {
        case missingNag
        case missingScannableNag
        case missingLock

        var errorDescription: String? {
            switch self {
            case .missingNag: "That nag no longer exists."
            case .missingScannableNag: "That nag no longer has a key to scan."
            case .missingLock: "That lock no longer exists."
            }
        }
    }
}
