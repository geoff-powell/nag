@preconcurrency import FamilyControls
import Foundation
import NagKit
import Observation
@preconcurrency import UserNotifications

/// The app's single source of truth. Views read `state` and call these methods; every change is written
/// to the shared store (so extensions see it), pushed to iCloud, and followed by a sync of shields,
/// DeviceActivity schedules and notifications.
@MainActor
@Observable
final class AppModel {
    let store: SharedStore
    private(set) var state: NagState
    private(set) var screenTimeStatus: AuthorizationStatus
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined

    var calendar: Calendar { .current }

    @ObservationIgnored private var changeObservation: SharedStore.ChangeObservation?
    @ObservationIgnored private var cloudSync: CloudTaskSync?
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(store: SharedStore) {
        self.store = store
        self.state = store.load()
        self.screenTimeStatus = AuthorizationCenter.shared.authorizationStatus
    }

    func start() {
        // Extensions write to the store too (a schedule locking, a timed unlock expiring).
        changeObservation = store.observeChanges { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        let cloud = CloudTaskSync(store: store) { [weak self] in
            Task { @MainActor in
                self?.reload()
                self?.sync()
            }
        }
        cloudSync = cloud
        cloud.start()
        sync()
    }

    func becameActive() {
        reload()
        cloudSync?.reconcile()
        sync()
        Task { await refreshPermissions() }
    }

    func reload() {
        state = store.load()
    }

    /// Applies a change to the stored state, then syncs everything that depends on it.
    func update(_ change: (inout NagState) -> Void) {
        state = store.update { state in
            change(&state)
            return state
        }
        cloudSync?.reconcile()
        sync()
    }

    /// Runs NagEngine after any earlier sync finishes, so syncs never overlap.
    func sync() {
        let previous = syncTask
        let store = store
        syncTask = Task {
            await previous?.value
            await NagEngine.sync(store: store)
            reload()
        }
    }

    func waitForSync() async {
        await syncTask?.value
    }

    // MARK: - Nags

    var outstandingCount: Int {
        state.tasks.filter { $0.isOutstanding(at: .now) }.count
    }

    /// The key a nag must be scanned with, if it has one that still exists.
    func proofKey(for task: NagTask) -> UnlockKey? {
        task.proof.keyID.flatMap(state.key)
    }

    func saveTask(_ task: NagTask) {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.updatedAt = .now
        update { state in
            if let index = state.tasks.firstIndex(where: { $0.id == task.id }) {
                if state.tasks[index].startAt != task.startAt {
                    task.snoozedUntil = nil
                    task.snoozeCount = 0
                }
                state.tasks[index] = task
            } else {
                state.tasks.append(task)
            }
        }
    }

    func canDeleteTask(_ id: UUID) -> Bool {
        !state.isTaskRequiredByEngagedLock(id)
    }

    func deleteTask(_ id: UUID) {
        guard canDeleteTask(id) else { return }
        update { $0.deleteTask(id, at: .now) }
    }

    /// Marks a nag done. Nags that need a key scan go through `complete(_:scannedFingerprint:)` instead.
    func complete(_ id: UUID) {
        guard let task = state.task(id), proofKey(for: task) == nil else { return }
        mutateTask(id) { $0.complete(at: .now, calendar: calendar) }
    }

    /// Marks a nag done if `fingerprint` matches its key. Returns false for the wrong tag or code.
    @discardableResult
    func complete(_ id: UUID, scannedFingerprint fingerprint: String) -> Bool {
        guard let task = state.task(id) else { return false }
        if let key = proofKey(for: task), key.fingerprint != fingerprint { return false }
        mutateTask(id) { $0.complete(at: .now, calendar: calendar) }
        return true
    }

    func reopen(_ id: UUID) {
        mutateTask(id) { $0.reopen(at: .now) }
    }

    func snooze(_ id: UUID) {
        mutateTask(id) { _ = $0.snooze(at: .now) }
    }

    func clearFinished() {
        let finished = state.tasks.filter { $0.isFinished && canDeleteTask($0.id) }.map(\.id)
        guard !finished.isEmpty else { return }
        update { state in
            for id in finished { state.deleteTask(id, at: .now) }
        }
    }

    func completeFromNotification(_ id: UUID) async {
        reload()
        complete(id)
        await waitForSync()
    }

    func snoozeFromNotification(_ id: UUID) async {
        reload()
        snooze(id)
        await waitForSync()
    }

    private func mutateTask(_ id: UUID, _ change: (inout NagTask) -> Void) {
        update { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
            change(&state.tasks[index])
        }
    }

    // MARK: - Locks

    func profile(_ id: UUID) -> LockProfile? {
        state.profile(id)
    }

    func evaluate(_ profile: LockProfile, steps: Int?, now: Date = .now) -> [RequirementStatus] {
        UnlockEvaluator.evaluate(profile, state: state, steps: steps, now: now, calendar: calendar)
    }

    /// Saves a lock's settings. Never changes whether it's locked: that only happens through the
    /// lock and unlock methods, so editing can't be used as a way out.
    func saveProfile(_ profile: LockProfile) {
        update { state in
            if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) {
                var updated = profile
                updated.status = state.profiles[index].status
                updated.lastScheduledLockAt = state.profiles[index].lastScheduledLockAt
                updated.autoLockPausedUntil = state.profiles[index].autoLockPausedUntil
                state.profiles[index] = updated
            } else {
                state.profiles.append(profile)
            }
        }
    }

    func deleteProfile(_ id: UUID) {
        guard let profile = state.profile(id), !profile.isEngaged else { return }
        ShieldController.clear(profileID: id)
        update { $0.profiles.removeAll { $0.id == id } }
    }

    func lockNow(_ id: UUID) {
        mutateProfile(id) { $0.lock(at: .now) }
    }

    func startWaitTimer(_ id: UUID) {
        mutateProfile(id) { $0.requestUnlock(at: .now) }
    }

    func recordProof(profileID: UUID, requirementID: UUID) {
        mutateProfile(profileID) { $0.recordProof(requirementID) }
    }

    /// Unlocks if every requirement is met. `steps` comes from the pedometer for walk requirements.
    @discardableResult
    func unlock(_ id: UUID, steps: Int?) -> Bool {
        guard let profile = state.profile(id), profile.isLocked,
              UnlockEvaluator.allMet(profile, state: state, steps: steps, now: .now, calendar: calendar)
        else { return false }
        mutateProfile(id) { $0.grantUnlock(at: .now) }
        return true
    }

    func relockNow(_ id: UUID) {
        mutateProfile(id) { $0.relockNow(at: .now) }
    }

    var emergencyUnlocksLeft: Int {
        state.emergencyUnlocksLeft(at: .now, calendar: calendar)
    }

    func emergencyUnlock(_ id: UUID) {
        guard emergencyUnlocksLeft > 0, state.profile(id)?.isEngaged == true else { return }
        update { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
            state.profiles[index].emergencyUnlock(at: .now)
            state.settings.emergencyUnlocksUsed.append(.now)
        }
    }

    private func mutateProfile(_ id: UUID, _ change: (inout LockProfile) -> Void) {
        update { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
            change(&state.profiles[index])
        }
    }

    // MARK: - Keys

    func key(matching fingerprint: String) -> UnlockKey? {
        state.keys.first { $0.fingerprint == fingerprint }
    }

    /// Adds a key. Returns the name of an existing key if this tag or code is already paired.
    func addKey(_ key: UnlockKey) -> String? {
        if let existing = self.key(matching: key.fingerprint) { return existing.name }
        update { $0.keys.append(key) }
        return nil
    }

    func canDeleteKey(_ id: UUID) -> Bool {
        !state.isKeyRequiredByEngagedLock(id)
    }

    func deleteKey(_ id: UUID) {
        guard canDeleteKey(id) else { return }
        update { $0.keys.removeAll { $0.id == id } }
    }

    // MARK: - Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        update { change(&$0.settings) }
    }

    func finishOnboarding() {
        updateSettings { $0.hasOnboarded = true }
    }

    // MARK: - Permissions

    func refreshPermissions() async {
        notificationStatus = await NotificationSync.authorizationStatus()
        screenTimeStatus = AuthorizationCenter.shared.authorizationStatus
        let approved = screenTimeStatus == .approved
        if state.settings.screenTimeApproved != approved {
            updateSettings { $0.screenTimeApproved = approved }
        }
    }

    func requestNotifications() async {
        _ = await NotificationSync.requestAuthorization()
        await refreshPermissions()
        sync()
    }

    /// Asks for Screen Time access. Returns an error message if it wasn't granted.
    func requestScreenTime() async -> String? {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            await refreshPermissions()
            return error.localizedDescription
        }
        await refreshPermissions()
        return nil
    }
}
