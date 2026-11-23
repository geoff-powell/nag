import CloudKit
import Foundation
import NagKit
import Observation
import UIKit

/// Accountability buddy: shares chosen nags and locks with one person through CloudKit, shows what
/// others shared with you, and turns buddies' nudges into gentle notifications.
///
/// Opt-in. Nothing touches CloudKit until the user turns on sharing or accepts someone's invitation.
/// The decisions (what to share, what changed, which nudges to show) are in NagCore; this only moves
/// records.
@MainActor
@Observable
final class BuddyController {
    /// What others shared with this device.
    private(set) var friends: [BuddyFriend] = []
    private(set) var isWorking = false
    /// The last thing that went wrong, in plain words.
    var errorMessage: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let makeService: () -> (any BuddyCloudService)?
    @ObservationIgnored private var cachedService: (any BuddyCloudService)?
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var ownerSyncTask: Task<Void, Never>?
    @ObservationIgnored private var lastPublishedState: NagState?
    @ObservationIgnored private var sharingDelegate: SharingDelegate?

    static let debounce: Duration = .seconds(2)

    init(model: AppModel, makeService: @escaping () -> (any BuddyCloudService)? = { CloudBuddyService.fromBundle() }) {
        self.model = model
        self.makeService = makeService
    }

    /// Created on first use, so CloudKit isn't touched until the feature is on.
    private var service: (any BuddyCloudService)? {
        if cachedService == nil { cachedService = makeService() }
        return cachedService
    }

    private var settings: BuddySettings { model?.state.buddy ?? BuddySettings() }

    // MARK: - Owner

    /// Called whenever local state changes. Publishes shared items after a short pause, so a burst of
    /// changes is one write.
    func stateChanged(_ state: NagState) {
        guard state.buddy.sharingEnabled, state != lastPublishedState else { return }
        lastPublishedState = state
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.syncOwner()
        }
    }

    func enableSharing() async {
        await run {
            guard let service = self.service else { throw BuddyError.notConfigured }
            try await service.prepareOwnZone()
            UIApplication.shared.registerForRemoteNotifications()
        }
        guard errorMessage == nil else { return }
        model?.update { $0.buddy.sharingEnabled = true }
        await syncOwner()
    }

    /// Deletes everything shared, including the invitation. The buddy loses access right away.
    func stopSharing() async {
        await run {
            // Without a container nothing was ever shared.
            try await self.service?.stopSharing()
        }
        guard errorMessage == nil else { return }
        lastPublishedState = nil
        model?.update { $0.buddy.sharingEnabled = false }
    }

    func setShared(_ id: UUID, _ isShared: Bool) {
        model?.update { $0.buddy.setShared(id, isShared, at: .now) }
    }

    /// Publishes shared items, and shows and clears any nudges waiting. Runs after any earlier sync.
    func syncOwner() async {
        let previous = ownerSyncTask
        let task = Task { @MainActor in
            await previous?.value
            await self.performOwnerSync()
        }
        ownerSyncTask = task
        await task.value
    }

    private func performOwnerSync() async {
        guard let model, settings.sharingEnabled, let service else { return }
        do {
            let remote = try await service.fetchOwnZone()
            model.reload()
            let state = model.state
            let now = Date.now
            let desired = BuddyPlanner.items(for: state, now: now, calendar: model.calendar)
            let changes = BuddyPlanner.changes(
                desired: desired,
                remote: remote.items,
                sharedIDs: state.buddy.shared.ids,
                deletedTaskIDs: state.deletedTaskIDs
            )
            let delivery = BuddyNudgeInbox.process(
                remote.nudges,
                items: desired,
                lastDelivered: state.buddy.receivedNudges,
                now: now
            )
            try await service.apply(changes, deletingNudges: delivery.consumed)
            if delivery.lastDelivered != state.buddy.receivedNudges {
                model.update { $0.buddy.receivedNudges = delivery.lastDelivered }
            }
            for notice in delivery.notices {
                await NotificationSync.buddyNudge(notice)
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Shows the system sheet for inviting a buddy, or managing the one already invited.
    func presentInvite() async {
        guard let service else {
            errorMessage = BuddyError.notConfigured.localizedDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.prepareOwnZone()
            await syncOwner()
            let share = try await service.share()
            let controller = UICloudSharingController(share: share, container: service.container)
            // One buddy, who needs write access to leave nudges. Never public.
            controller.availablePermissions = [.allowPrivate, .allowReadWrite]
            let delegate = SharingDelegate()
            sharingDelegate = delegate
            controller.delegate = delegate
            Self.topViewController()?.present(controller, animated: true)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Buddy

    func accept(_ metadata: CKShare.Metadata) async {
        await run {
            guard let service = self.service else { throw BuddyError.notConfigured }
            try await service.accept(metadata)
        }
        model?.update { $0.buddy.following = true }
        await refreshFriends()
    }

    func refreshFriends() async {
        guard settings.following, let service else { return }
        do {
            friends = try await service.fetchFriends()
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func lastNudge(for item: BuddyItem) -> Date? {
        settings.sentNudges[item.id.uuidString]
    }

    func canNudge(_ item: BuddyItem, now: Date = .now) -> Bool {
        BuddyNudgeRule.canNudge(item, lastSentAt: lastNudge(for: item), now: now)
    }

    func nudge(_ item: BuddyItem, of friend: BuddyFriend) async {
        guard canNudge(item) else { return }
        let nudge = BuddyNudge(itemID: item.id, from: friend.myName, sentAt: .now)
        await run {
            guard let service = self.service else { throw BuddyError.notConfigured }
            try await service.sendNudge(nudge, to: friend)
        }
        guard errorMessage == nil else { return }
        model?.update { $0.buddy.sentNudges[item.id.uuidString] = nudge.sentAt }
    }

    func leave(_ friend: BuddyFriend) async {
        await run {
            guard let service = self.service else { throw BuddyError.notConfigured }
            try await service.leave(friend)
        }
        guard errorMessage == nil else { return }
        friends.removeAll { $0.id == friend.id }
        let leftIDs = Set(friend.items.map(\.id.uuidString))
        model?.update { state in
            state.buddy.sentNudges = state.buddy.sentNudges.filter { !leftIDs.contains($0.key) }
            if friends.isEmpty { state.buddy.following = false }
        }
    }

    // MARK: - Lifecycle

    /// Foreground and background refresh: catch nudges a push may have missed.
    func refresh() async {
        if settings.sharingEnabled { await syncOwner() }
        if settings.following { await refreshFriends() }
    }

    // MARK: - Helpers

    private func run(_ body: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await body()
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: any Error) -> String {
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: return "Sign in to iCloud in Settings to use a buddy."
            case .networkUnavailable, .networkFailure: return "Couldn't reach iCloud. Nag will try again later."
            case .quotaExceeded: return "Your iCloud storage is full."
            default: break
            }
        }
        return error.localizedDescription
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    enum BuddyError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            "This build of Nag isn't set up for iCloud sharing."
        }
    }
}

private final class SharingDelegate: NSObject, UICloudSharingControllerDelegate {
    func itemTitle(for csc: UICloudSharingController) -> String? { "My nags" }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: any Error) {}
}
